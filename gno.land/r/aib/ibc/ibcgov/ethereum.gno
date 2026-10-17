package ibcgov

import (
	"bytes"
	"chain"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/aib/encoding/abi/v0"
	"gno.land/p/aib/encoding/ethaddr/v0"
	"gno.land/p/aib/ibc/app/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
)

// The governance channel to Ethereum (ADR pr6375 §5.4, R11): this realm is the
// IBC app on port gov of the gno core, and sends every Ethereum-bound decision
// to IBCAdmin as one packet over the governance epoch's client:
//
//	payload: source port "gov" (this realm's port on the gno core),
//	         destination port "ibcgov" (IBCAdmin's on the Ethereum router),
//	         version "ibcgov-1", encoding "application/x-ibcgov"
//	value:   version u8 (= 1) ‖ epoch u32 ‖ seq u64 ‖ kind u8 ‖ params
//
// big-endian, at most 1024 bytes, params the Solidity ABI encoding of the
// kind's tuple (abi.encode of its fields; see the New…Request builders). seq
// is the epoch's own contiguous sequence of Ethereum-bound decisions, from 1,
// separate from the ledger's numbers; a number is bound to its bytes in the
// transaction that records the decision and dispatches it, so no number is
// ever skipped, reused or sent with other bytes. Epochs start at 1 when the
// channel is bound to its client and rise only with a route replacement.
//
// Anyone can call the core's SendPacket for port gov, so OnSendPacket accepts
// a send only against the one-time dispatch authorization this realm created
// for it, bound to the client, the epoch, the seq and the payload's hash, and
// consumes it. Every callback accepts the core as its only caller.
//
// IBCAdmin answers with an app acknowledgement
// epoch u32 ‖ seq u64 ‖ status u8 ‖ redispatch u8 (status 1 recorded,
// 2 buffered, 3 duplicate, 4 conflict, 5 spent), or an error acknowledgement
// (out of its window, a stale epoch, a forgery). A timeout, an error
// acknowledgement of the current epoch, a malformed acknowledgement or
// redispatch = 1 make the decision re-dispatchable: anyone then calls
// Redispatch, which sends the same seq with identical bytes. A packet of a
// past epoch is never sent again.

const (
	// GovPort is this realm's port on the gno core: the packets' source port.
	GovPort = "gov"
	// GovDestPort is IBCAdmin's port on the Ethereum router: the packets'
	// destination port. ADR pr6375 §5.4 names it "gov" on both sides, but
	// eureka v3.0.2's router refuses a custom port id shorter than four
	// characters, so IBCAdmin registers "ibcgov" (gno-eth-ibc IBCAdmin.PORT).
	GovDestPort = "ibcgov"
	GovVersion  = "ibcgov-1"
	GovEncoding = "application/x-ibcgov"

	EnvelopeVersion = uint8(1)
	envelopeHeader  = 14
	// MaxEnvelope bounds an envelope. ADR pr6375 §5.4 says 512 bytes, but a
	// kind 6 carrying gno.land's two-item merkle prefix ("main",
	// "/pv/vm:gno.land/r/aib/ibc/core:") encodes to 558 bytes, so both sides
	// bound it at 1024 (gno-eth-ibc IBCAdminStorage.MAX_ENVELOPE).
	MaxEnvelope = 1024

	// GovPacketTimeout is how far ahead a governance packet times out, in
	// seconds (the core accepts up to 24 hours).
	GovPacketTimeout = int64(6 * 3600)

	ackLen = 14
)

// App acknowledgement statuses.
const (
	StatusRecorded  = uint8(1)
	StatusBuffered  = uint8(2)
	StatusDuplicate = uint8(3)
	StatusConflict  = uint8(4)
	StatusSpent     = uint8(5)
)

// The Ethereum-bound decision kinds (ADR pr6375 §5.4).
const (
	KindCancel          = uint8(1)
	KindUnpause         = uint8(2)
	KindSeats           = uint8(3)
	KindLimits          = uint8(4)
	KindVoucher         = uint8(5)
	KindClient          = uint8(6)
	KindUpgrade         = uint8(7)
	KindRole            = uint8(8)
	KindHandOver        = uint8(9)
	KindRouteReplace    = uint8(10)
	KindRouteSettings   = uint8(11)
	KindSettle          = uint8(12)
	KindReopen          = uint8(13)
	maxSettleItems      = 8 // what a 1024-byte envelope holds with a 64-byte client id
	maxCancelRanges     = 16
	adminRoleID         = uint64(0)  // AccessManager's ADMIN_ROLE: never granted or revoked by kind 8
	publicRoleID        = ^uint64(0) // AccessManager's PUBLIC_ROLE
	maxEthSeatsPerCall  = 6
	maxEthGuardianSeats = 2
)

// epochRec is a governance epoch: the gno client its packets go over and the
// last seq bound in it.
type epochRec struct {
	client string
	last   uint64
	opened int64 // block height
}

// dispatch is one Ethereum-bound decision's packet: its bytes, immutable once
// bound, and what the channel answered.
type dispatch struct {
	epoch      uint32
	seq        uint64
	kind       uint8
	body       []byte
	decision   int64
	status     uint8  // the last app acknowledgement's status, 0 before any
	redispatch bool   // may be sent again (Redispatch)
	inFlight   bool   // a packet is out and not yet acknowledged or timed out
	transport  uint64 // the core sequence of the last packet sent
	sends      int
	event      string // the last thing that happened, in words
}

type authorization struct {
	client string
	epoch  uint32
	seq    uint64
	hash   [32]byte
}

var (
	epoch       uint32   // the current governance epoch, 0 until the channel is bound
	epochs      avl.Tree // epochKey -> *epochRec
	dispatches  avl.Tree // dispatchKey -> *dispatch
	pendingAuth *authorization
)

func epochKey(e uint32) string {
	s := strconv.FormatUint(uint64(e), 10)
	return strings.Repeat("0", 10-len(s)) + s
}

func dispatchKey(e uint32, seq uint64) string {
	s := u64s(seq)
	return epochKey(e) + "/" + strings.Repeat("0", 20-len(s)) + s
}

func epochRecOf(e uint32) *epochRec {
	v := epochs.Get(epochKey(e))
	if v == nil {
		return nil
	}
	return v.(*epochRec)
}

func dispatchOf(e uint32, seq uint64) *dispatch {
	v := dispatches.Get(dispatchKey(e, seq))
	if v == nil {
		return nil
	}
	return v.(*dispatch)
}

// Envelope is the canonical envelope of a governance packet.
func Envelope(e uint32, seq uint64, kind uint8, params []byte) []byte {
	out := make([]byte, envelopeHeader, envelopeHeader+len(params))
	out[0] = EnvelopeVersion
	binary.BigEndian.PutUint32(out[1:5], e)
	binary.BigEndian.PutUint64(out[5:13], seq)
	out[13] = kind
	return append(out, params...)
}

// ParseEnvelope reads an envelope's prefix; ok is false when it is too short
// or of another version.
func ParseEnvelope(b []byte) (e uint32, seq uint64, kind uint8, params []byte, ok bool) {
	if len(b) < envelopeHeader || b[0] != EnvelopeVersion {
		return 0, 0, 0, nil, false
	}
	return binary.BigEndian.Uint32(b[1:5]), binary.BigEndian.Uint64(b[5:13]), b[13], b[envelopeHeader:], true
}

// Epoch is the current governance epoch (0 until bound), and EpochClient its
// gno client.
func Epoch() uint32 { return epoch }

func EpochClient() string {
	if r := epochRecOf(epoch); r != nil {
		return r.client
	}
	return ""
}

// LastSeq is the last seq bound in epoch e.
func LastSeq(e uint32) uint64 {
	if r := epochRecOf(e); r != nil {
		return r.last
	}
	return 0
}

// DispatchBody is the envelope bound to (e, seq), copied, or nil.
func DispatchBody(e uint32, seq uint64) []byte {
	if d := dispatchOf(e, seq); d != nil {
		return append([]byte{}, d.body...)
	}
	return nil
}

// DispatchState says what the channel answered for (e, seq): the last app
// acknowledgement status (0 if none), whether it may be re-dispatched, whether
// a packet is in flight, how many times it was sent and the last event.
func DispatchState(e uint32, seq uint64) (status uint8, redispatch, inFlight bool, sends int, event string) {
	d := dispatchOf(e, seq)
	if d == nil {
		return 0, false, false, 0, ""
	}
	return d.status, d.redispatch, d.inFlight, d.sends, d.event
}

// DispatchTransport is the core sequence of the last packet sent for (e,
// seq), 0 if none.
func DispatchTransport(e uint32, seq uint64) uint64 {
	if d := dispatchOf(e, seq); d != nil {
		return d.transport
	}
	return 0
}

// bindChannel opens epoch 1 over client.
func bindChannel(client string) {
	epoch = 1
	epochs.Set(epochKey(epoch), &epochRec{client: client, opened: chainHeight()})
	chain.Emit("GovEpoch", "epoch", "1", "client", client)
}

// nextEpoch opens the next epoch over client (a route replacement): the old
// epoch's unacknowledged decisions are never sent again.
func nextEpoch(client string) {
	epoch++
	epochs.Set(epochKey(epoch), &epochRec{client: client, opened: chainHeight()})
	chain.Emit("GovEpoch", "epoch", strconv.FormatUint(uint64(epoch), 10), "client", client)
}

// bind binds the next seq of the current epoch to kind and params and sends
// it. It returns the seq.
func bind(cur realm, decision int64, kind uint8, params []byte) (uint64, string) {
	rec := epochRecOf(epoch)
	if rec == nil {
		return 0, "the governance channel is not bound"
	}
	// Every failure the core's send would raise is refused here, so the
	// decision is spent rather than aborted and left pending.
	switch {
	case core.Paused():
		return 0, "the core is paused: no governance packet can be sent"
	case core.IsAppPaused(GovPort):
		return 0, "the gov app is paused on the core"
	case core.IsClientRetired(rec.client):
		return 0, "the epoch's client " + rec.client + " is retired"
	case core.ClientStatus(rec.client) != "Active":
		return 0, "the epoch's client " + rec.client + " is " + core.ClientStatus(rec.client) + ", not Active"
	case core.CounterpartyClientID(rec.client) == "":
		return 0, "the epoch's client " + rec.client + " has no counterparty"
	}
	if latest, ok := core.ClientLatestTimestamp(rec.client); !ok || latest >= uint64(now()+GovPacketTimeout) {
		return 0, "the epoch's client " + rec.client + " is ahead of the packet's timeout"
	}
	seq := rec.last + 1
	body := Envelope(epoch, seq, kind, params)
	if len(body) > MaxEnvelope {
		return 0, "the envelope is " + strconv.Itoa(len(body)) + " bytes, above " + strconv.Itoa(MaxEnvelope)
	}
	rec.last = seq
	d := &dispatch{epoch: epoch, seq: seq, kind: kind, body: body, decision: decision}
	dispatches.Set(dispatchKey(epoch, seq), d)
	send(cur, d)
	return seq, ""
}

// send sends d's bytes over its epoch's client, under a one-time dispatch
// authorization OnSendPacket consumes.
func send(cur realm, d *dispatch) {
	rec := epochRecOf(d.epoch)
	pendingAuth = &authorization{client: rec.client, epoch: d.epoch, seq: d.seq, hash: sha256.Sum256(d.body)}
	transportSeq := core.SendPacket(cross(cur), types.MsgSendPacket{
		SourceClient:     rec.client,
		TimeoutTimestamp: uint64(now() + GovPacketTimeout),
		Payloads: []types.Payload{{
			SourcePort:      GovPort,
			DestinationPort: GovDestPort,
			Version:         GovVersion,
			Encoding:        GovEncoding,
			Value:           append([]byte{}, d.body...),
		}},
	})
	if pendingAuth != nil {
		panic("ibcgov: the dispatch authorization was not consumed")
	}
	d.inFlight, d.redispatch, d.transport = true, false, transportSeq
	d.sends++
	d.event = "sent as packet " + u64s(transportSeq)
	chain.Emit("GovPacketSent", "epoch", strconv.FormatUint(uint64(d.epoch), 10), "seq", u64s(d.seq),
		"kind", strconv.Itoa(int(d.kind)), "client", rec.client, "sequence", u64s(transportSeq))
}

// Redispatch sends decision (e, seq) again, with identical bytes, once the
// channel made it re-dispatchable (a timeout, an error acknowledgement, a
// malformed acknowledgement or redispatch = 1) and no packet of it is in
// flight. Anyone may call it. A past epoch's decisions are never sent again.
func Redispatch(cur realm, e uint32, seq uint64) {
	d := dispatchOf(e, seq)
	if d == nil {
		panic("ibcgov: no dispatched decision " + strconv.FormatUint(uint64(e), 10) + "/" + u64s(seq))
	}
	if e != epoch {
		panic("ibcgov: epoch " + strconv.FormatUint(uint64(e), 10) + " is past: its decisions are never sent again")
	}
	if d.inFlight || !d.redispatch {
		panic("ibcgov: decision " + u64s(seq) + " is not re-dispatchable (" + d.event + ")")
	}
	send(cur, d)
}

// ---------------------------------------------------------------- the app

// App is the IBC app registered on port gov of the gno core.
type App struct{}

var _ app.IBCApp = &App{}

// assertCoreCaller panics unless the IBC core invokes the callback: the
// methods are exported and any realm can hold an *App.
func assertCoreCaller(cur realm) {
	if p := cur.Previous().PkgPath(); p != CorePath {
		panic("ibcgov: the gov callbacks are the IBC core's, not " + who(0, cur.Previous()))
	}
}

// OnSendPacket accepts a send on port gov only against the dispatch
// authorization this realm created for it, and consumes the authorization.
func (a *App) OnSendPacket(cur realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	assertCoreCaller(cur)
	auth := pendingAuth
	pendingAuth = nil
	if auth == nil {
		return ufmt.Errorf("ibcgov: governance packets are sent by ibcgov's decisions only")
	}
	if payload.SourcePort != GovPort || payload.DestinationPort != GovDestPort || payload.Version != GovVersion || payload.Encoding != GovEncoding {
		return ufmt.Errorf("ibcgov: not a governance payload")
	}
	if sourceClient != auth.client {
		return ufmt.Errorf("ibcgov: authorized for client %s, not %s", auth.client, sourceClient)
	}
	if sha256.Sum256(payload.Value) != auth.hash {
		return ufmt.Errorf("ibcgov: the payload differs from the authorized one")
	}
	e, seq, _, _, ok := ParseEnvelope(payload.Value)
	if !ok || e != auth.epoch || seq != auth.seq {
		return ufmt.Errorf("ibcgov: the envelope differs from the authorized one")
	}
	return nil
}

// OnRecvPacket refuses every packet: this chain sends governance, it does not
// receive it.
func (a *App) OnRecvPacket(cur realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult {
	assertCoreCaller(cur)
	return types.RecvPacketResult{Status: types.PacketStatus_Failure}
}

// ownDispatch is the dispatch a packet's payload carries, if it is ours.
func ownDispatch(payload types.Payload) *dispatch {
	e, seq, _, _, ok := ParseEnvelope(payload.Value)
	if !ok {
		return nil
	}
	d := dispatchOf(e, seq)
	if d == nil || !bytes.Equal(d.body, payload.Value) {
		return nil
	}
	return d
}

// OnAcknowledgementPacket reads IBCAdmin's answer. It never fails: an
// acknowledgement this realm cannot use leaves the decision re-dispatchable,
// and re-sending identical bytes is always safe.
func (a *App) OnAcknowledgementPacket(cur realm, sourceClient, destinationClient string, sequence uint64, acknowledgement []byte, payload types.Payload) error {
	assertCoreCaller(cur)
	d := ownDispatch(payload)
	if d == nil {
		return nil
	}
	if d.transport == sequence {
		d.inFlight = false
	}
	current := d.epoch == epoch
	if bytes.Equal(acknowledgement, types.UniversalErrorAcknowledgement()) {
		d.redispatch = current
		d.event = "error acknowledgement"
		if !current {
			d.event += " of a past epoch"
		}
		chain.Emit("GovAck", "epoch", strconv.FormatUint(uint64(d.epoch), 10), "seq", u64s(d.seq), "status", "error")
		return nil
	}
	e, seq, status, redispatch, ok := ParseAck(acknowledgement)
	if !ok || e != d.epoch || seq != d.seq {
		d.redispatch = current
		d.event = "malformed acknowledgement"
		chain.Emit("GovAck", "epoch", strconv.FormatUint(uint64(d.epoch), 10), "seq", u64s(d.seq), "status", "malformed")
		return nil
	}
	d.status = status
	// redispatch = 1 means: send the same bytes again, whatever the status
	// (a cancel beyond IBCAdmin's window is acknowledged buffered with it).
	d.redispatch = current && redispatch
	d.event = "acknowledged: " + statusWord(d.status)
	if redispatch {
		d.event += ", redispatch"
	}
	chain.Emit("GovAck", "epoch", strconv.FormatUint(uint64(d.epoch), 10), "seq", u64s(d.seq), "status", statusWord(d.status))
	return nil
}

// OnTimeoutPacket makes a decision of the current epoch re-dispatchable.
func (a *App) OnTimeoutPacket(cur realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	assertCoreCaller(cur)
	d := ownDispatch(payload)
	if d == nil {
		return nil
	}
	if d.transport == sequence {
		d.inFlight = false
	}
	d.redispatch = d.epoch == epoch
	d.event = "timed out"
	chain.Emit("GovTimeout", "epoch", strconv.FormatUint(uint64(d.epoch), 10), "seq", u64s(d.seq))
	return nil
}

// ParseAck reads IBCAdmin's app acknowledgement
// epoch u32 ‖ seq u64 ‖ status u8 ‖ redispatch u8 (big-endian, 14 bytes);
// ok is false for any other length, a status outside 1–5 or a redispatch byte
// other than 0 or 1.
func ParseAck(b []byte) (e uint32, seq uint64, status uint8, redispatch bool, ok bool) {
	if len(b) != ackLen || b[12] < StatusRecorded || b[12] > StatusSpent || b[13] > 1 {
		return 0, 0, 0, false, false
	}
	return binary.BigEndian.Uint32(b[0:4]), binary.BigEndian.Uint64(b[4:12]), b[12], b[13] == 1, true
}

func statusWord(s uint8) string {
	switch s {
	case StatusRecorded:
		return "recorded"
	case StatusBuffered:
		return "buffered"
	case StatusDuplicate:
		return "duplicate"
	case StatusConflict:
		return "conflict"
	case StatusSpent:
		return "spent"
	}
	return "none"
}

// --------------------------------------------------- Ethereum-bound kinds

// ethParams is an Ethereum-bound decision: dispatched at once, its delay
// runs in IBCAdmin (ADR pr6375 §6.6).
type ethParams struct {
	kind   uint8
	params []byte
	epoch  uint32 // a cancel: the epoch whose numbers it names (0: any)
}

func (p *ethParams) apply(cur realm, t int64) (string, string) {
	if p.epoch != 0 && p.epoch != epoch {
		return "", "the cancel names numbers of epoch " + strconv.FormatUint(uint64(p.epoch), 10) + ", which is past"
	}
	seq, refusal := bind(cur, ledger.Last(), p.kind, p.params)
	if refusal != "" {
		return "", refusal
	}
	return "dispatched as epoch " + strconv.FormatUint(uint64(epoch), 10) + " seq " + u64s(seq), ""
}

func ethRequest(cur realm, name string, kind uint8, text string, params []byte) Request {
	return ethRequestIn(cur, name, kind, text, params, 0)
}

func ethRequestIn(cur realm, name string, kind uint8, text string, params []byte, bound uint32) Request {
	if epochRecOf(epoch) == nil {
		panic("ibcgov: the governance channel is not bound")
	}
	if envelopeHeader+len(params) > MaxEnvelope {
		panic("ibcgov: the envelope would be " + strconv.Itoa(envelopeHeader+len(params)) + " bytes, above " + strconv.Itoa(MaxEnvelope))
	}
	p := &ethParams{kind: kind, params: params, epoch: bound}
	text = "ethereum kind " + strconv.Itoa(int(kind)) + " (" + name + "): " + text
	return propose(cur, "eth "+name, text, func(cur realm, made, t int64) {
		decide(cur, "eth "+name, text, p, made, t, false)
	})
}

func mustEthAddr(s string) [20]byte {
	a, err := ethaddr.Parse(s)
	if err != nil {
		panic("ibcgov: " + err.Error())
	}
	return [20]byte(a)
}

// mustEthClientID is a client id of the Ethereum router: one it generated
// ("client-N") or a custom id (types.IsValidRouterClientID), not an SDK id.
func mustEthClientID(s string) string {
	if !types.IsValidRouterClientID(s) {
		panic("ibcgov: not an Ethereum router client id: " + s)
	}
	return s
}

// mustCustomEthClientID is a router client id that governance adds (kind 6
// op 1, and kind 10's new client): eureka's router takes only a valid custom
// id there (IBCIdentifiers.validateCustomIBCIdentifier: 4 to 128 characters
// of its alphabet, not starting with "client-" or "channel-"), so any other
// decision would only be spent on Ethereum.
func mustCustomEthClientID(s string) string {
	if !types.IsValidCustomClientID(s) {
		panic("ibcgov: a router client id added by governance is a custom id: 4 to 128 characters of a-z A-Z 0-9 . _ + - # [ ] < >, not starting with client- or channel-: " + s)
	}
	return s
}

func mustHash(s string) [32]byte {
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil || len(b) != 32 {
		panic("ibcgov: not a 32-byte hash in hex: " + s)
	}
	var h [32]byte
	copy(h[:], b)
	return h
}

func mustHexBytes(s string) []byte {
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		panic("ibcgov: not hex: " + s)
	}
	return b
}

func mustUint256(name, s string) abi.Value {
	v, err := abi.Uint256Decimal(s)
	if err != nil {
		panic("ibcgov: " + name + ": " + err.Error())
	}
	return v
}

func ethAddrText(a [20]byte) string { return ethaddr.Address(a).String() }

// NewEthCancelRequest (kind 1) cancels Ethereum-bound decisions of the
// current epoch: ranges is a comma-separated list of "from-to" (inclusive,
// at most 16), each within the numbers already dispatched. IBCAdmin applies
// it at recording, whatever its own seq. It is spent if a route replacement
// opens another epoch before it is recorded.
func NewEthCancelRequest(cur realm, ranges string) Request {
	items := splitList(ranges)
	if len(items) == 0 || len(items) > maxCancelRanges {
		panic("ibcgov: name 1 to 16 ranges")
	}
	last := LastSeq(epoch)
	var vals []abi.Value
	for _, it := range items {
		i := strings.Index(it, "-")
		from, to := it, it
		if i >= 0 {
			from, to = it[:i], it[i+1:]
		}
		f, err1 := strconv.ParseUint(from, 10, 64)
		g, err2 := strconv.ParseUint(to, 10, 64)
		if err1 != nil || err2 != nil || f < 1 || g < f || g > last {
			panic("ibcgov: not a range of dispatched numbers (1-" + u64s(last) + "): " + it)
		}
		vals = append(vals, abi.Tuple(abi.Uint64(f), abi.Uint64(g)))
	}
	return ethRequestIn(cur, "cancel", KindCancel, "cancel "+strings.Join(items, ",")+" of epoch "+strconv.FormatUint(uint64(epoch), 10),
		abi.Encode(abi.Array(vals...)), epoch)
}

// NewEthUnpauseRequest (kind 2) unpauses an object on Ethereum after 24 hours
// there: object 1 is the transfer route of the router client clientID, object
// 2 IBCAdmin itself (clientID empty).
func NewEthUnpauseRequest(cur realm, object int, clientID string) Request {
	switch object {
	case 1:
		mustEthClientID(clientID)
	case 2:
		if clientID != "" {
			panic("ibcgov: object 2 (IBCAdmin) names no client")
		}
	default:
		panic("ibcgov: object 1 (a transfer route) or 2 (IBCAdmin)")
	}
	return ethRequest(cur, "unpause", KindUnpause, "unpause object "+strconv.Itoa(object)+" "+clientID,
		abi.Encode(abi.Uint64(uint64(object)), abi.String(clientID)))
}

// NewEthSeatsRequest (kind 3) sets IBCAdmin's seats: changes is a
// comma-separated list of "seat:0xaddress" (seats 0–3 guardians, 4–5 watch
// keys; the zero address vacates), at most two guardian seats.
func NewEthSeatsRequest(cur realm, changes string) Request {
	items := splitList(changes)
	if len(items) == 0 || len(items) > maxEthSeatsPerCall {
		panic("ibcgov: name 1 to 6 seat changes")
	}
	seen := map[int]bool{}
	guardians := 0
	var vals []abi.Value
	var parts []string
	for _, it := range items {
		i := strings.Index(it, ":")
		if i < 0 {
			panic("ibcgov: a seat change is seat:address")
		}
		n, err := strconv.Atoi(it[:i])
		if err != nil || n < 0 || n >= SeatCount || seen[n] {
			panic("ibcgov: not a seat, or named twice: " + it[:i])
		}
		seen[n] = true
		if n < GuardianSeats {
			guardians++
		}
		a := mustEthAddr(strings.TrimSpace(it[i+1:]))
		vals = append(vals, abi.Tuple(abi.Uint64(uint64(n)), abi.Address(a)))
		parts = append(parts, strconv.Itoa(n)+"="+ethAddrText(a))
	}
	if guardians > maxEthGuardianSeats {
		panic("ibcgov: a decision changes at most two guardian seats")
	}
	return ethRequest(cur, "seats", KindSeats, "set seats "+strings.Join(parts, ","), abi.Encode(abi.Array(vals...)))
}

// NewEthLimitsRequest (kind 4) sets a token's limits on the route of the
// router client clientID: per-message maximum, day cap, refund cap, and for
// Ethereum-native tokens the send maximum and minimum (0 unset), in base units
// as decimal digits. IBCAdmin applies a pure lowering at recording, anything
// else after 7 days.
func NewEthLimitsRequest(cur realm, clientID, token, maxPerMessage, dayCap, refundCap, sendMax, sendMin string) Request {
	mustEthClientID(clientID)
	tok := mustEthAddr(token)
	vals := []abi.Value{abi.String(clientID), abi.Address(tok),
		mustUint256("maxPerMessage", maxPerMessage), mustUint256("dayCap", dayCap), mustUint256("refundCap", refundCap),
		mustUint256("sendMax", sendMax), mustUint256("sendMin", sendMin)}
	text := "limits of " + ethAddrText(tok) + " on " + clientID + ": maxPerMessage=" + maxPerMessage + " dayCap=" + dayCap +
		" refundCap=" + refundCap + " sendMax=" + sendMax + " sendMin=" + sendMin
	return ethRequest(cur, "limits", KindLimits, text, abi.Encode(vals...))
}

// NewEthVoucherRequest (kind 5) registers the GnoVoucher of a gno denom on
// the route of clientID (setCustomERC20), pinned to its code hash.
func NewEthVoucherRequest(cur realm, clientID, baseDenom, voucher, codeHash string) Request {
	mustEthClientID(clientID)
	if !isDenom(baseDenom) {
		panic("ibcgov: not a denom: " + baseDenom)
	}
	v, h := mustEthAddr(voucher), mustHash(codeHash)
	text := "voucher of " + baseDenom + " on " + clientID + ": " + ethAddrText(v) + " code hash " + hex.EncodeToString(h[:])
	return ethRequest(cur, "voucher", KindVoucher, text, abi.Encode(abi.String(clientID), abi.String(baseDenom), abi.Address(v), abi.Bytes32(h)))
}

// NewEthClientRequest (kind 6) adds (op 1) or migrates (op 2) a router light
// client: clientID is the router's client id, counterpartyClientID the gno
// client it tracks (op 1), merklePrefix a comma-separated list of hex items,
// lightClient the contract and codeHash its code hash.
func NewEthClientRequest(cur realm, op int, clientID, counterpartyClientID, merklePrefix, lightClient, codeHash string) Request {
	if op != 1 && op != 2 {
		panic("ibcgov: op 1 (add) or 2 (migrate)")
	}
	if op == 1 {
		mustCustomEthClientID(clientID)
		if core.ClientType(counterpartyClientID) == "" {
			panic("ibcgov: the counterparty " + counterpartyClientID + " is not a gno client")
		}
	} else {
		mustEthClientID(clientID)
		if counterpartyClientID != "" {
			mustEthClientID(counterpartyClientID)
		}
	}
	var prefix []abi.Value
	var prefixText []string
	for _, item := range strings.Split(merklePrefix, ",") {
		b := mustHexBytes(strings.TrimSpace(item))
		prefix = append(prefix, abi.Bytes(b))
		prefixText = append(prefixText, hex.EncodeToString(b))
	}
	lc, h := mustEthAddr(lightClient), mustHash(codeHash)
	text := "client op " + strconv.Itoa(op) + " " + clientID + " counterparty " + counterpartyClientID + " prefix [" +
		strings.Join(prefixText, ",") + "] light client " + ethAddrText(lc) + " code hash " + hex.EncodeToString(h[:])
	return ethRequest(cur, "client", KindClient, text, abi.Encode(abi.Uint64(uint64(op)), abi.String(clientID),
		abi.String(counterpartyClientID), abi.Array(prefix...), abi.Address(lc), abi.Bytes32(h)))
}

// NewEthUpgradeRequest (kind 7) upgrades a proxy to an implementation pinned
// to its code hash, with an optional call (hex, may be empty).
func NewEthUpgradeRequest(cur realm, proxy, implementation, codeHash, call string) Request {
	p, im, h := mustEthAddr(proxy), mustEthAddr(implementation), mustHash(codeHash)
	c := []byte{}
	if call != "" {
		c = mustHexBytes(call)
	}
	text := "upgrade " + ethAddrText(p) + " to " + ethAddrText(im) + " code hash " + hex.EncodeToString(h[:]) + " call " + hex.EncodeToString(c)
	return ethRequest(cur, "upgrade", KindUpgrade, text, abi.Encode(abi.Address(p), abi.Address(im), abi.Bytes32(h), abi.Bytes(c)))
}

// NewEthRoleRequest (kind 8) grants or revokes a non-admin AccessManager role
// (the relayer allow-list). ADMIN_ROLE (0) and PUBLIC_ROLE are refused.
func NewEthRoleRequest(cur realm, grant bool, roleID uint64, account string) Request {
	if roleID == adminRoleID || roleID == publicRoleID {
		panic("ibcgov: kind 8 never names ADMIN_ROLE or PUBLIC_ROLE")
	}
	a := mustEthAddr(account)
	verb := "revoke"
	if grant {
		verb = "grant"
	}
	return ethRequest(cur, "role", KindRole, verb+" role "+u64s(roleID)+" to "+ethAddrText(a),
		abi.Encode(abi.Bool(grant), abi.Uint64(roleID), abi.Address(a)))
}

// NewEthHandOverRequest (kind 9) swaps IBCAdmin's executor to exec, pinned to
// its code hash, with an optional one-time migration call (hex).
func NewEthHandOverRequest(cur realm, exec, codeHash, migrationCall string) Request {
	e, h := mustEthAddr(exec), mustHash(codeHash)
	c := []byte{}
	if migrationCall != "" {
		c = mustHexBytes(migrationCall)
	}
	text := "hand over to " + ethAddrText(e) + " code hash " + hex.EncodeToString(h[:]) + " migration " + hex.EncodeToString(c)
	return ethRequest(cur, "hand-over", KindHandOver, text, abi.Encode(abi.Address(e), abi.Bytes32(h), abi.Bytes(c)))
}

// NewEthRouteReplacementRequest (kind 10) retires and freezes the router
// client oldClientID, migrates its route to newClientID (a custom id added by
// kind 6 first) and opens IBCAdmin's next epoch over it. suspectFrom is the
// Ethereum block from which acknowledgements and timeouts processed through
// the old client are suspect (ADR pr6375 §5.4, §7.12): every send record
// processed at or after it must be settled by kind 12 before kind 13 reopens
// the route.
func NewEthRouteReplacementRequest(cur realm, oldClientID, newClientID string, suspectFrom uint64) Request {
	mustEthClientID(oldClientID)
	mustCustomEthClientID(newClientID)
	if oldClientID == newClientID {
		panic("ibcgov: the clients differ")
	}
	return ethRequest(cur, "route replacement", KindRouteReplace, "replace route "+oldClientID+" by "+newClientID+", suspect from Ethereum block "+u64s(suspectFrom),
		abi.Encode(abi.String(oldClientID), abi.String(newClientID), abi.Uint64(suspectFrom)))
}

// NewEthRouteSettingsRequest (kind 11) sets the quarantine of the route of
// clientID after a validator-set transition, in seconds (0 disables it).
func NewEthRouteSettingsRequest(cur realm, clientID string, quarantineSeconds uint64) Request {
	mustEthClientID(clientID)
	return ethRequest(cur, "route settings", KindRouteSettings, "quarantine of "+clientID+": "+u64s(quarantineSeconds)+" s",
		abi.Encode(abi.String(clientID), abi.Uint64(quarantineSeconds)))
}

// NewEthSettleRequest (kind 12) applies a reconciliation's outcomes to the
// send records of clientId, the router client a route replacement retired
// (ADR pr6375 §5.4, §7.12): items is a comma-separated list of
// "sequence:action:amount" (amount in base units as decimal digits), at most
// 8, each sequence once:
//
//   - 1 a genuine refund: pay its remainder, amount exactly the entitlement
//     minus what was already refunded (a refund is never cut short), 0 for one
//     paid in full already, which only marks the record settled;
//   - 2 reject a queued refund none of which was paid, amount 0;
//   - 3 settled as delivered, no refund paid, amount 0;
//   - 4 a forged refund: the unpaid remainder is rejected and what was
//     already paid is recorded as a loss, atomically; amount is exactly what
//     was paid;
//   - 5 a forged receive: sequence is an inbound sequence on the retired
//     client, amount what its receive released or minted, booked as a loss
//     once.
//
// IBCAdmin applies it after 7 days; each send record is settled at most once.
func NewEthSettleRequest(cur realm, clientID, items string) Request {
	mustEthClientID(clientID)
	list := splitList(items)
	if len(list) == 0 || len(list) > maxSettleItems {
		panic("ibcgov: name 1 to " + strconv.Itoa(maxSettleItems) + " settlement items")
	}
	// A sequence is named once per direction: action 5 names an inbound
	// sequence, the others an outbound one, separate spaces.
	seen := map[string]bool{}
	var vals []abi.Value
	for _, it := range list {
		parts := strings.Split(it, ":")
		if len(parts) != 3 {
			panic("ibcgov: a settlement item is sequence:action:amount, not " + it)
		}
		seq, err1 := strconv.ParseUint(parts[0], 10, 64)
		action, err2 := strconv.ParseUint(parts[1], 10, 8)
		if err1 != nil || err2 != nil || seq == 0 || seen[settleItemKey(seq, action)] || action < 1 || action > 5 {
			panic("ibcgov: not a settlement item, or a sequence named twice in its direction: " + it)
		}
		amount := mustUint256("amount", parts[2])
		zero := strings.TrimLeft(parts[2], "0") == ""
		if ((action == 4 || action == 5) && zero) || ((action == 2 || action == 3) && !zero) {
			panic("ibcgov: a forged refund or receive names its positive amount, a rejection or a delivery 0: " + it)
		}
		seen[settleItemKey(seq, action)] = true
		vals = append(vals, abi.Tuple(abi.Uint64(seq), abi.Uint64(action), amount))
	}
	return ethRequest(cur, "settle", KindSettle, "settle sends of "+clientID+": "+strings.Join(list, ","),
		abi.Encode(abi.String(clientID), abi.Array(vals...)))
}

// NewEthReopenRequest (kind 13) reopens the route of clientID that a route
// replacement or the emergency recovery closed (ADR pr6375 §5.4). IBCAdmin
// applies it after 7 days; Ethereum refuses it while any send record of the
// route's retired client ids is open, and records every loss not
// recapitalized as an accepted deficit.
func NewEthReopenRequest(cur realm, clientID string) Request {
	mustEthClientID(clientID)
	return ethRequest(cur, "reopen", KindReopen, "reopen the route of "+clientID, abi.Encode(abi.String(clientID)))
}
