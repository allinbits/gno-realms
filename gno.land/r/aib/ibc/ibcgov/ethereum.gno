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
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
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
// redispatch = 1 ask for the decision to be sent again; anyone may call
// Redispatch, which sends the same seq with identical bytes in a fresh
// packet, after any answer but a conflict (see Redispatch), a success
// included. A packet of a past epoch is never sent again.
//
// The epoch moves in two phases (ADR pr6375 §7.12, "Governance epoch switch,
// two-phase and authenticated"). A route replacement here retires the old
// client for the transfer port only: the epoch stays over it, so a decision
// in flight, the kind 10 among them, can still be re-sent. When IBCAdmin
// executes the matching kind 10 (or the emergency recovery), it sends an
// epoch notice from its port over the new client to this realm's port:
//
//	payload: source port "ibcgov" (IBCAdmin's), destination port "gov",
//	         version "ibcgov-1", encoding "application/x-ibcgov"
//	value:   version u8 (= 1) ‖ epoch u32 ‖ newClient
//
// big-endian, newClient the router's client id the notice comes from (the
// kind 10's new client), the rest of the bytes. It is the only packet this
// realm receives. Ethereum raises its epoch by one per kind 10 or emergency
// recovery it executes, and sends a notice over each step's new client. This
// realm records the transitions it expects, in router client ids, each
// bound to the local gno client governance approved to carry the epoch over
// the new router client (expected, kept apart from the transfer aliases): a
// kind 10 when it is dispatched, an emergency recovery by
// NewExpectRecoveryRequest; a client may have up to maxExpected expected
// successors, as only one of competing kind 10s can execute. A notice of
// epoch current + k (k from 1 to maxNoticeSteps) is accepted only when the
// k-th step of a path of expected transitions from the epoch client's
// counterparty leads to its source and is bound to exactly the local client
// it arrives on, its proof verified by the core through that client (Active,
// its counterparty the notice's source): the epoch then moves there, past any
// step in between, and the old epoch's client is retired for the gov port
// (for good once its route replacement has executed here too); the path's
// intermediate clients are kept, off the graph. A gno client on
// an expected path from the epoch's is never retired for the gov port
// before. The
// app acknowledgement is epoch u32 ‖ seq u64 (0) ‖ status u8 ‖ redispatch u8
// (0): status 1 when it switches, 3 for the notice of the epoch already
// switched to. Anything else is refused with an error acknowledgement.

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
	maxSettleItems      = 8          // what a 1024-byte envelope holds with a 64-byte client id
	maxCancelRanges     = 14         // what a 1024-byte envelope holds: 78 + 64 bytes a range
	adminRoleID         = uint64(0)  // AccessManager's ADMIN_ROLE: never granted or revoked by kind 8
	publicRoleID        = ^uint64(0) // AccessManager's PUBLIC_ROLE
	maxEthSeatsPerCall  = 6
	maxEthGuardianSeats = 2
)

// NoticeVersion is the version byte that opens an epoch notice; noticeHeader
// is the length of its fixed part, the version and the epoch.
const (
	NoticeVersion = uint8(1)
	noticeHeader  = 5
)

// EpochNotice is the canonical epoch notice of IBCAdmin (see above).
func EpochNotice(e uint32, newClient string) []byte {
	out := make([]byte, noticeHeader, noticeHeader+len(newClient))
	out[0] = NoticeVersion
	binary.BigEndian.PutUint32(out[1:5], e)
	return append(out, newClient...)
}

// ParseEpochNotice reads an epoch notice; ok is false when it is too short,
// of another version, or names no client.
func ParseEpochNotice(b []byte) (e uint32, newClient string, ok bool) {
	if len(b) <= noticeHeader || b[0] != NoticeVersion {
		return 0, "", false
	}
	return binary.BigEndian.Uint32(b[1:5]), string(b[noticeHeader:]), true
}

// epochRec is a governance epoch: the gno client its packets go over and the
// last seq bound in it.
type epochRec struct {
	client string
	last   uint64
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
	redispatch bool   // the channel asked for it to be sent again (Redispatch takes it after any answer but a conflict)
	inFlight   bool   // a packet is out and not yet acknowledged or timed out
	transport  uint64 // the core sequence of the last packet sent
	retransmit bool   // a governed, single-use authorization to re-send it after a conflict (NewRetransmitRequest)
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
	// expected is the governance transitions this realm expects Ethereum to
	// make, kept apart from the transfer app's route aliases (ADR pr6375
	// §7.12, "expected transitions"), in router client ids: for an old
	// client, its expected successors, at most maxExpected, never
	// overwritten or removed (an expectation never confirmed by a notice
	// costs nothing). A kind 10 records one when it is dispatched, and
	// NewExpectRecoveryRequest one for an emergency recovery.
	expected avl.Tree // old router client id -> []expEdge
	// awaitingGov is the gno clients a route replacement retired for
	// transfers only, being on an expected path of the epoch: each is
	// retired for good once the epoch moved off every path through it.
	awaitingGov avl.Tree // gno client id -> true
	// approvedLocal is every local client an expected transition approves;
	// proven is the epoch notices the core proved over one of them, more
	// than one step on, waiting for ApplyEpochNotice and their path.
	approvedLocal avl.Tree // gno client id -> true
	govPruneAfter string   // where PruneGovRetirements stopped
	proven        avl.Tree // provenKey(epoch, client) -> *provenNotice
	// tombstones is the transitions removed or released before an epoch
	// switch superseded them: each keeps its local client, and those of the
	// transitions beyond it, retained for governance (never retired for the
	// gov port, so they can be approved again and carry their notices).
	// Live transitions and tombstones share one budget of maxLive; a
	// transition moving between the two (a removal, a release, a
	// re-approval) leaves the count unchanged. A switch drops those whose
	// old router client the new epoch client reaches through neither, and a
	// governed purge drops one at a time (NewPurgeTombstoneRequest).
	tombstones avl.Tree // tombKey(old, next, local) -> *tomb
)

const (
	// maxNoticeSteps bounds k, the epochs a notice moves through at once:
	// the graph's own bound, as a path of expected transitions never has
	// more steps than the graph has transitions. Ethereum executes
	// transitions with no cap of its own on how many come between two
	// notices gno receives, so no shorter bound is assumed of it.
	maxNoticeSteps = maxLive
	// maxExpected bounds a router client's expected successors.
	maxExpected = 4
	// maxLive bounds the transitions kept, pending, active and tombstoned,
	// together: a new transition that would pass it is refused (a dispatch,
	// a recovery expectation), and an epoch switch drops every transition
	// and tombstone no longer reachable from the new epoch's client. So
	// every walk of the graph reads at most maxLive edges, exactly, with no
	// "too many to tell" case. 64 holds a chain of 64 steps, or 16 steps of
	// 4 competing successors, more than any incident needs.
	maxLive = 64
)

// expEdge is an expected transition from an old router client: the router
// client replacing it, and the local gno client governance approved to
// carry the epoch over it (tracking that router client), the only one a
// notice for it is accepted over.
//
// A transition is an intent from the moment its kind 10 is dispatched (or
// its recovery expectation recorded): it counts against the old client's
// successors and keeps its clients open for governance at once, and grants
// notice authority (active) only once its 7-day, hold-deferred expectation
// decision applies. A refused, spent or cancelled expectation releases it.
type expEdge struct {
	to, local string
	active    bool
	gen       uint64 // this intent's generation: its owners are indexed under it (ownerKey)
	owners    int    // how many expectation decisions own it, pending: an intent lives while one does
}

// The owners of every intent, by (transition, generation, decision): each
// ownership check and release is one keyed lookup, whatever the number of
// decisions recorded for one transition. A generation is given to an intent
// when it is created, so an owner of an intent an epoch switch dropped
// never owns a later one of the same transition. Each decision removes its
// own entry when it resolves (applied, refused, spent or cancelled).
var (
	owned   avl.Tree // ownerKey -> true
	intents uint64   // the last intent generation given
)

func ownerKey(old, next, local string, gen uint64, owner int64) string {
	return old + "|" + next + "|" + local + "|" + u64s(gen) + "|" + itoa(owner)
}

func expectedOf(old string) []expEdge {
	if v := expected.Get(old); v != nil {
		return v.([]expEdge)
	}
	return nil
}

// checkLocal is why the gno client local cannot carry the governance epoch
// over the router client remote, or "": it must be an Active Ethereum client,
// not retired, its counterparty remote, authenticating the identity of the
// route the governance channel rides. Its identity alone proves nothing (a
// fabricated checkpoint can copy it): the decision names the client, and
// only that client is accepted.
func checkLocal(local, remote string) string {
	want := govIdentity
	got, _ := core.ClientRouteIdentity(local)
	switch {
	case core.ClientType(local) != ethereum.ClientType:
		return local + " is not an Ethereum client"
	case core.IsClientRetiredFor(local, GovPort):
		return local + " is retired"
	case core.ClientStatus(local) != "Active":
		return local + " is not Active"
	case core.CounterpartyClientID(local) != remote:
		return local + "'s counterparty is not " + remote
	case want == "":
		return "the governance channel's route records no identity"
	case got != want:
		return local + " does not authenticate the governance route's identity"
	}
	return ""
}

// liveEdges is how many transitions are kept, pending and active.
var liveEdges int

// checkExpect is why the transition old → next over the gno client local
// cannot be expected, or "": its old router client must be reachable from
// the epoch client (through live transitions or tombstones), the local
// client must qualify (checkLocal), and a transition not already live must
// fit the old client's successors (live ones only) and, unless it is
// tombstoned, the joint budget of maxLive.
func checkExpect(old, next, local string) string {
	if epoch == 0 {
		return "the governance channel is not bound"
	}
	remotes, _ := retained()
	if !remotes[old] {
		return "router client " + old + " is not reachable from the governance epoch's client: Ethereum is past it" + gnoClientHint(old)
	}
	if refusal := checkLocal(local, next); refusal != "" {
		return refusal
	}
	succ := expectedOf(old)
	for _, x := range succ {
		if x.to == next && x.local == local {
			return ""
		}
	}
	if len(succ) >= maxExpected {
		return "router client " + old + " has " + strconv.Itoa(maxExpected) + " expected successors already, intents included"
	}
	// A tombstoned transition approved again moves back into the graph:
	// the joint count does not change, nor does the graph's shape.
	if tombstones.Has(tombKey(old, next, local)) {
		return ""
	}
	// The graph stays acyclic, live transitions and tombstones together:
	// Ethereum never returns to a router client it left (a kind 10 or a
	// recovery always creates a new one), so a cycle is never a real
	// history, and every path of the graph is simple.
	if next == old || reaches(next, old) {
		return "router client " + next + " reaches " + old + " already: the transition would close a cycle"
	}
	if liveEdges+tombstones.Size() >= maxLive {
		return "the governance graph holds " + strconv.Itoa(maxLive) + " transitions already, intents and tombstones included: an epoch switch frees those it leaves behind, and a purge frees a tombstone"
	}
	return ""
}

// tomb is a removed or released transition kept for retention: its local
// client, and every transition still recorded beyond its new router client.
type tomb struct{ old, to, local string }

func tombKey(old, next, local string) string { return old + "|" + next + "|" + local }

// entomb records the transition old → next over local, just dropped from
// the graph, as a tombstone: it takes the place the live transition had in
// the joint budget, so it needs no room.
func entomb(old, next, local string) {
	k := tombKey(old, next, local)
	if tombstones.Has(k) {
		return
	}
	tombstones.Set(k, &tomb{old: old, to: next, local: local})
	chain.Emit("GovTombstone", "from", old, "to", next, "client", local)
}

// tombsOf is the tombstones leaving router client old.
func tombsOf(old string) []*tomb {
	var out []*tomb
	tombstones.Iterate(old+"|", old+"}", func(_ string, v any) bool { // '}' follows '|'
		out = append(out, v.(*tomb))
		return false
	})
	return out
}

// Tombstones is how many removed or released transitions still retain their
// local clients for governance.
func Tombstones() int { return tombstones.Size() }

func setEdges(old string, edges []expEdge) {
	if len(edges) == 0 {
		expected.Remove(old)
		return
	}
	expected.Set(old, edges)
}

// intend records the transition old → next over local as an intent owned by
// the expectation decision owner (adding the owner to it when it is
// recorded already), and returns the intent's generation, which the
// decision keeps; its caller checked it (checkExpect).
func intend(old, next, local string, owner int64) uint64 {
	succ := append([]expEdge{}, expectedOf(old)...)
	for i := range succ {
		if succ[i].to == next && succ[i].local == local {
			succ[i].owners++
			setEdges(old, succ)
			owned.Set(ownerKey(old, next, local, succ[i].gen, owner), true)
			return succ[i].gen
		}
	}
	intents++
	setEdges(old, append(succ, expEdge{to: next, local: local, gen: intents, owners: 1}))
	owned.Set(ownerKey(old, next, local, intents, owner), true)
	liveEdges++
	tombstones.Remove(tombKey(old, next, local)) // the graph retains it again
	chain.Emit("GovIntent", "from", old, "to", next, "client", local, "decision", itoa(owner))
	return intents
}

// expect makes the transition old → next over local active, recording it
// first if need be; its caller checked it (checkExpect).
func expect(old, next, local string) {
	succ := append([]expEdge{}, expectedOf(old)...)
	found := false
	for i := range succ {
		if succ[i].to == next && succ[i].local == local {
			succ[i].active, succ[i].owners, found = true, 0, true
		}
	}
	if !found {
		succ = append(succ, expEdge{to: next, local: local, active: true})
		liveEdges++
	}
	setEdges(old, succ)
	tombstones.Remove(tombKey(old, next, local))
	approvedLocal.Set(local, true)
	chain.Emit("GovExpect", "from", old, "to", next, "client", local)
}

// ownsIntent reports whether the intent old → next over local of
// generation gen is still pending and owned by the decision owner: an epoch
// switch that left it behind, or a release, dropped it otherwise. A keyed
// lookup, among at most maxExpected successors.
func ownsIntent(old, next, local string, gen uint64, owner int64) bool {
	for _, x := range expectedOf(old) {
		if x.to == next && x.local == local && !x.active && x.gen == gen {
			return owned.Has(ownerKey(old, next, local, gen, owner))
		}
	}
	return false
}

// disown removes owner's entry, whatever became of the intent.
func disown(old, next, local string, gen uint64, owner int64) {
	owned.Remove(ownerKey(old, next, local, gen, owner))
}

// release drops owner from the intent old → next over local: the intent
// goes with its last owner, unless it is active, leaving a tombstone in its
// place that keeps its local client retained for governance.
func release(old, next, local string, gen uint64, owner int64) {
	if !owned.Has(ownerKey(old, next, local, gen, owner)) {
		return // not an owner (any more): nothing to release
	}
	disown(old, next, local, gen, owner)
	succ := append([]expEdge{}, expectedOf(old)...)
	for i := range succ {
		x := succ[i]
		if x.to != next || x.local != local || x.active || x.gen != gen {
			continue
		}
		if x.owners > 1 {
			succ[i].owners--
			setEdges(old, succ)
			return
		}
		setEdges(old, append(succ[:i:i], succ[i+1:]...))
		liveEdges--
		entomb(old, next, local)
		return
	}
}

// retained is every router client the epoch client's router counterparty
// reaches, itself included, and every local client retained for
// governance, through live transitions (pending or active) and tombstones
// alike: the graph an epoch switch keeps and retention protects. Each router
// client is expanded once, so the walk reads every transition and tombstone
// at most once: at most maxLive in all.
func retained() (remotes, locals map[string]bool) {
	if epoch == 0 {
		return nil, nil
	}
	start := core.CounterpartyClientID(EpochClient())
	remotes, locals = map[string]bool{start: true}, map[string]bool{}
	front := []string{start}
	for len(front) > 0 {
		var next []string
		visit := func(to, local string) {
			locals[local] = true
			if !remotes[to] {
				remotes[to] = true
				next = append(next, to)
			}
		}
		for _, c := range front {
			for _, x := range expectedOf(c) {
				visit(x.to, x.local)
			}
			for _, t := range tombsOf(c) {
				visit(t.to, t.local)
			}
		}
		front = next
	}
	return remotes, locals
}

// reaches reports whether router client from reaches target through live
// transitions and tombstones: each router client expanded once, at most
// maxLive edges read.
func reaches(from, target string) bool {
	seen := map[string]bool{from: true}
	front := []string{from}
	for len(front) > 0 {
		var next []string
		for _, c := range front {
			tos := []string{}
			for _, x := range expectedOf(c) {
				tos = append(tos, x.to)
			}
			for _, t := range tombsOf(c) {
				tos = append(tos, t.to)
			}
			for _, to := range tos {
				if to == target {
					return true
				}
				if !seen[to] {
					seen[to] = true
					next = append(next, to)
				}
			}
		}
		front = next
	}
	return false
}

// pruneUnreachable drops every transition and tombstone whose old router
// client the epoch client's counterparty no longer reaches through either
// (an epoch switch left it behind, superseded): bounded by maxLive.
func pruneUnreachable() {
	seen, _ := retained()
	var drop []string
	expected.Iterate("", "", func(old string, v any) bool {
		if !seen[old] {
			drop = append(drop, old)
		}
		return false
	})
	for _, old := range drop {
		liveEdges -= len(expectedOf(old))
		expected.Remove(old)
	}
	var dropTombs []string
	tombstones.Iterate("", "", func(k string, v any) bool {
		if !seen[v.(*tomb).old] {
			dropTombs = append(dropTombs, k)
		}
		return false
	})
	for _, k := range dropTombs {
		tombstones.Remove(k)
	}
}

// onExpectedPath reports whether the gno client c carries the governance
// epoch or is the local client of a transition, pending, active or
// tombstoned (removed or released, not yet superseded), reachable from it
// at any distance through either (any path in the graph is within a
// notice's maxNoticeSteps): such a client is never retired for the gov port, so a
// notice over it can still arrive and the epoch's decisions still be
// re-sent. Exact: the graph holds at most maxLive transitions.
func onExpectedPath(c string) bool {
	if epoch == 0 {
		return false
	}
	if c == EpochClient() {
		return true
	}
	_, locals := retained()
	return locals[c]
}

// awaitGov notes a gno client retired for transfers only, to retire for good
// once the epoch has moved off every expected path through it.
func awaitGov(c string) { awaitingGov.Set(c, true) }

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

// govIdentity is the identity of the route the governance channel was bound
// over (RouteIdentity): every client approved to carry a later epoch must
// authenticate it.
var govIdentity string

// bindChannel opens epoch 1 over client.
func bindChannel(client string) {
	govIdentity = RouteIdentity(client)
	setEpoch(1, client)
}

// setEpoch opens epoch e over client (IBCAdmin's epoch notice): the earlier
// epochs' unacknowledged decisions are never sent again.
func setEpoch(e uint32, client string) {
	epoch = e
	epochs.Set(epochKey(epoch), &epochRec{client: client})
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
	case core.IsClientRetiredFor(rec.client, GovPort):
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

// Redispatch sends decision (e, seq) of the current epoch again, in a fresh
// transport packet with identical bytes, whenever no packet of it is in
// flight, whatever the channel answered before: a timeout, an error or
// malformed acknowledgement, redispatch = 1, and a success too (recorded,
// buffered, duplicate, spent), since a success acknowledgement may have
// been forged by a compromised Ethereum-side verifier while the decision
// never reached IBCAdmin. IBCAdmin deduplicates by seq and hash: the same
// bytes at a seq it holds are a duplicate (status 3, redispatch 0), a no-op.
// The one exception is a conflict acknowledged without redispatch = 1:
// IBCAdmin re-flags itself on every conflict, so a free re-send would let
// anyone keep it deferred; it is re-sent once per governed authorization
// (NewRetransmitRequest), which this call uses up. Anyone may call it. A past epoch's decisions are
// never sent again.
func Redispatch(cur realm, e uint32, seq uint64) {
	d := dispatchOf(e, seq)
	if d == nil {
		panic("ibcgov: no dispatched decision " + strconv.FormatUint(uint64(e), 10) + "/" + u64s(seq))
	}
	if e != epoch {
		panic("ibcgov: epoch " + strconv.FormatUint(uint64(e), 10) + " is past: its decisions are never sent again")
	}
	if d.inFlight || (d.status == StatusConflict && !d.redispatch && !d.retransmit) {
		panic("ibcgov: decision " + u64s(seq) + " is not re-dispatchable (" + d.event + ")")
	}
	if d.status == StatusConflict && !d.redispatch {
		d.retransmit = false // used once: another re-send needs another decision
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

// OnRecvPacket takes IBCAdmin's epoch notice, the only packet this realm
// receives (see above), and refuses every other: an error acknowledgement.
func (a *App) OnRecvPacket(cur realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult {
	assertCoreCaller(cur)
	e, status, refusal := takeNotice(cur, sourceClient, destinationClient, payload)
	if refusal != "" {
		chain.Emit("GovNotice", "client", destinationClient, "status", "refused", "reason", refusal)
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	ack := make([]byte, ackLen)
	binary.BigEndian.PutUint32(ack[0:4], e)
	ack[12] = status
	return types.RecvPacketResult{Status: types.PacketStatus_Success, Acknowledgement: ack}
}

// takeNotice applies an epoch notice received over client from the router's
// client source, or says why it refuses it.
func takeNotice(cur realm, source, client string, payload types.Payload) (uint32, uint8, string) {
	if payload.SourcePort != GovDestPort || payload.DestinationPort != GovPort || payload.Version != GovVersion || payload.Encoding != GovEncoding {
		return 0, 0, "not an epoch notice payload"
	}
	e, named, ok := ParseEpochNotice(payload.Value)
	switch {
	case !ok:
		return 0, 0, "a malformed epoch notice"
	case named != source:
		return 0, 0, "the notice names " + named + ", not " + source + ", the client it came from"
	case epoch != 0 && e == epoch && client == EpochClient():
		return e, StatusDuplicate, "" // the switch happened already: acknowledged again
	}
	if epoch == 0 || e <= epoch || e-epoch > maxNoticeSteps {
		return 0, 0, "the notice is of epoch " + strconv.FormatUint(uint64(e), 10) + ", not one of the next " + strconv.Itoa(maxNoticeSteps) + " after " + strconv.FormatUint(uint64(epoch), 10)
	}
	// Epoch current + k goes over a client reached from the epoch's through
	// exactly k expected transitions: Ethereum raised its epoch once per
	// kind 10 or recovery it executed, and sent a notice over each step's
	// new client. A later notice moves the epoch past the steps in between,
	// whose notices may never come (a client that failed meanwhile). The
	// next step (k = 1) is checked here, among at most maxExpected edges; a
	// later one is recorded as proven, and applied by anyone who names its
	// path (ApplyEpochNotice), checked in O(k): no search of the expected
	// graph, however it branches, ever refuses an authentic notice.
	k := int(e - epoch)
	if k > 1 {
		if !approvedLocal.Has(client) {
			return 0, 0, client + " is no client approved to carry a governance epoch"
		}
		proven.Set(provenKey(e, client), &provenNotice{source: source, gen: core.ClientTrustGeneration(client)})
		chain.Emit("GovNotice", "client", client, "epoch", strconv.FormatUint(uint64(e), 10), "status", "proven")
		return 0, 0, "epoch " + strconv.FormatUint(uint64(e), 10) + " is " + strconv.Itoa(k) + " steps on: recorded as proven, applied by ApplyEpochNotice with its path"
	}
	found := false
	for _, x := range expectedOf(core.CounterpartyClientID(EpochClient())) {
		if x.active && x.to == source && x.local == client {
			found = true
		}
	}
	if !found {
		return 0, 0, "epoch " + strconv.FormatUint(uint64(e), 10) + " is expected over no transition to " + source + " carried by " + client + " from " + core.CounterpartyClientID(EpochClient())
	}
	switchEpoch(cur, e, client, nil)
	return e, StatusRecorded, ""
}

// switchEpoch opens epoch e over client and retires for governance the old
// epoch's client, for good when its route replacement executed here (it is
// retired for transfers already), otherwise for the gov port, its
// replacement retiring the rest. That is the only client a switch retires:
// the path's intermediate clients (supplied by whoever applied the notice,
// not proven to be Ethereum's) and every other client its pruning
// disconnects (on a branch it left behind, a cancelled recovery's say) is
// taken out of awaitingGov and kept off the graph, its gov port open and
// inert, as a purge keeps the clients it disconnects, since Ethereum may
// still reach it another way (expected again, its notice applies). Its work
// is bounded: two walks of the graph.
func switchEpoch(cur realm, e uint32, client string, passed []string) {
	old := EpochClient()
	_, before := retained()
	setEpoch(e, client)
	pruneUnreachable()
	_, after := retained()
	for c := range before {
		if !after[c] && awaitingGov.Has(c) {
			awaitingGov.Remove(c)
		}
	}
	// Only the old epoch client: the notice of a later epoch proves
	// Ethereum has moved past it. The path's intermediate clients are named
	// by whoever applied the notice, not proven passed (another path to the
	// same client may be the one Ethereum took), so they are kept off the
	// graph like every client the pruning disconnects. Never the client
	// just adopted (the path is simple; this guards it).
	if old != client {
		retireForGov(cur, old)
		awaitingGov.Remove(old)
	}
	for _, c := range passed {
		awaitingGov.Remove(c)
	}
}

// PruneGovRetirements retires for governance up to n (1 to 64) of the gno
// clients a route replacement retired for transfers while they were on an
// expected path of the governance epoch, once they no longer are: anyone may
// call it. A safety net only: nothing leaves a client here once no path
// reaches it (a removal or a release leaves a tombstone that keeps it
// reachable; a switch and a purge take the clients they disconnect out of
// awaitingGov), and a switch retires the old epoch client itself, so a
// prune retires nothing a switch did not. A client on a path, or one whose paths cannot be told within the
// search's bounds, is kept for a later call. Each call visits n clients from
// where the last one stopped, wrapping round at the end, so a client kept
// never holds back those after it. It returns how many it retired.
func PruneGovRetirements(cur realm, n int) int {
	if n < 1 || n > 64 {
		panic("ibcgov: prune 1 to 64 clients a call")
	}
	// onExpectedPath, with the epoch client and the retained graph read
	// once: the walk changes neither.
	epochClient := EpochClient()
	_, locals := retained()
	var done []string
	seen := 0
	last := ""
	awaitingGov.Iterate(after(govPruneAfter), "", func(c string, _ any) bool {
		if seen == n {
			return true
		}
		seen++
		last = c
		if epoch == 0 || c != epochClient && !locals[c] {
			done = append(done, c)
		}
		return false
	})
	if seen < n {
		last = "" // the walk reached the end: the next starts over
	}
	govPruneAfter = last
	for _, c := range done {
		awaitingGov.Remove(c)
		retireForGov(cur, c)
	}
	return len(done)
}

// AwaitingGovRetirement is how many clients wait for PruneGovRetirements.
func AwaitingGovRetirement() int { return awaitingGov.Size() }

// provenNotice is an epoch notice the core proved over a local client: the
// router client it came from, and the local client's trust generation then.
type provenNotice struct {
	source string
	gen    uint64
}

func provenKey(e uint32, client string) string { return epochKey(e) + "|" + client }

// applicable reports whether the notice of epoch e recorded as proven
// over client from the router client source may still be applied: its
// epoch past the current and within maxNoticeSteps, and the client still
// vouching for it (Active, not retired for the gov port, at the trust
// generation it was proven under), as ApplyEpochNotice requires; the path
// it needs is checked by the caller.
func applicable(e uint32, client, source string) bool {
	if e <= epoch || e-epoch > maxNoticeSteps {
		return false
	}
	v := proven.Get(provenKey(e, client))
	if v == nil {
		return false
	}
	pn := v.(*provenNotice)
	return pn.source == source && core.ClientStatus(client) == "Active" && !core.IsClientRetiredFor(client, GovPort) && core.ClientTrustGeneration(client) == pn.gen
}

// pinnedBy is a client over which a notice recorded as proven may still be
// applied along a path that uses the transition from → to over local, or
// "": a path of active transitions, or (all, for a purge) one that may also
// take live and tombstoned transitions an approval could make active. ApplyEpochNotice needs a path of exactly e - current active
// transitions from the epoch client's router counterparty, ending at the
// notice's source over its client, so only a transition on such a path is
// pinned: one at step i of it leaves from a router client reached in exactly
// i - 1 steps, and either is the last step (to the source, over the notice's
// client) or leads on, in exactly the steps left, to that last step. The
// graph is acyclic (checkExpect), so every such walk of exact length is a
// simple path, the only kind ApplyEpochNotice accepts. Every
// recorded notice is read, not only the highest per client. Bounded: the
// graph holds at most maxLive edges and a path at most maxNoticeSteps
// steps, so each walk is at most 64 layers of 64 edges, and each notice
// looked up is a distinct (epoch, client) pair, deduplicated first.
func pinnedBy(from, to, local string, all bool) string {
	// The transitions a path may take: active ones only, or (all) every
	// live one and every tombstone, which an approval could make active.
	// Read once a router client: the graph does not change during the call.
	memo := map[string][]expEdge{}
	outs := func(c string) []expEdge {
		if out, ok := memo[c]; ok {
			return out
		}
		var out []expEdge
		for _, x := range expectedOf(c) {
			if x.active || all {
				out = append(out, x)
			}
		}
		if all {
			for _, t := range tombsOf(c) {
				out = append(out, expEdge{to: t.to, local: t.local})
			}
		}
		memo[c] = out
		return out
	}
	// The steps i - 1 (0 to 63) in which from is reached exactly.
	var at []int
	front := map[string]bool{core.CounterpartyClientID(EpochClient()): true}
	for d := 0; d < maxNoticeSteps && len(front) > 0; d++ {
		if front[from] {
			at = append(at, d)
		}
		next := map[string]bool{}
		for c := range front {
			for _, x := range outs(c) {
				next[x.to] = true
			}
		}
		front = next
	}
	if len(at) == 0 {
		return ""
	}
	type want struct {
		e              uint32
		client, source string
	}
	seen := map[want]bool{}
	var wants []want
	add := func(steps int, client, source string) {
		if steps > maxNoticeSteps {
			return
		}
		w := want{epoch + uint32(steps), client, source}
		if !seen[w] {
			seen[w] = true
			wants = append(wants, w)
		}
	}
	// The transition itself as the last step: k = d + 1.
	for _, d := range at {
		add(d+1, local, to)
	}
	// The last steps reached from to, j steps after the transition: k = d +
	// 1 + j + 1.
	front = map[string]bool{to: true}
	for j := 0; at[0]+j+2 <= maxNoticeSteps && len(front) > 0; j++ {
		next := map[string]bool{}
		for c := range front {
			for _, x := range outs(c) {
				next[x.to] = true
				for _, d := range at {
					add(d+j+2, x.local, x.to)
				}
			}
		}
		front = next
	}
	for _, w := range wants {
		if applicable(w.e, w.client, w.source) {
			return w.client
		}
	}
	return ""
}

// ApplyEpochNotice applies an epoch notice of epoch e that the core proved
// over client (OnRecvPacket recorded it, being more than one step on), along
// path, the k = e - current expected transitions from the epoch client's
// router counterparty, as comma-separated "routerClient/localClient" pairs
// ending with the notice's source and client: each must be a recorded
// expected transition with its local binding. Anyone may call it; it is
// checked in O(k), k at most maxNoticeSteps, 64 (ADR pr6375 §7.12).
func ApplyEpochNotice(cur realm, e uint32, client, path string) {
	v := proven.Get(provenKey(e, client))
	if v == nil {
		panic("ibcgov: no epoch notice of epoch " + strconv.FormatUint(uint64(e), 10) + " was proven over " + client)
	}
	pn := v.(*provenNotice)
	source := pn.source
	// The proof holds while the client that verified it does: Active, not
	// retired, and at the trust generation it was proven under (no freeze,
	// recovery, upgrade or migration since). Otherwise a freshly proven
	// notice is needed.
	switch {
	case core.ClientStatus(client) != "Active":
		panic("ibcgov: " + client + " is " + core.ClientStatus(client) + ": relay the notice again once it is Active")
	case core.IsClientRetiredFor(client, GovPort):
		panic("ibcgov: " + client + " is retired")
	case core.ClientTrustGeneration(client) != pn.gen:
		panic("ibcgov: " + client + "'s trust generation changed since the notice was proven: relay it again")
	}
	if epoch == 0 || e <= epoch || e-epoch > maxNoticeSteps {
		panic("ibcgov: epoch " + strconv.FormatUint(uint64(e), 10) + " is not one of the next " + strconv.Itoa(maxNoticeSteps) + " after " + strconv.FormatUint(uint64(epoch), 10))
	}
	steps := splitList(path)
	if len(steps) != int(e-epoch) {
		panic("ibcgov: the path names " + strconv.Itoa(len(steps)) + " transitions, not " + strconv.FormatUint(uint64(e-epoch), 10))
	}
	prev := core.CounterpartyClientID(EpochClient())
	var to, local string
	var passed []string
	// A simple path: no router client or local client twice, the epoch's
	// own included (the graph admits no cycle, so this only guards it).
	seenRouter := map[string]bool{prev: true}
	seenLocal := map[string]bool{EpochClient(): true}
	for i, st := range steps {
		j := strings.Index(st, "/")
		if j < 0 {
			panic("ibcgov: a step is routerClient/localClient, not " + st)
		}
		to, local = st[:j], st[j+1:]
		if seenRouter[to] || seenLocal[local] {
			panic("ibcgov: step " + strconv.Itoa(i+1) + " repeats a client of the path: " + st)
		}
		seenRouter[to], seenLocal[local] = true, true
		found := false
		for _, x := range expectedOf(prev) {
			if x.active && x.to == to && x.local == local {
				found = true
			}
		}
		if !found {
			panic("ibcgov: step " + strconv.Itoa(i+1) + ", " + prev + " -> " + to + " over " + local + ", is no expected transition")
		}
		if i < len(steps)-1 {
			passed = append(passed, local)
		}
		prev = to
	}
	if to != source || local != client {
		panic("ibcgov: the path ends at " + to + " over " + local + ", not the notice's " + source + " over " + client)
	}
	proven.Remove(provenKey(e, client))
	switchEpoch(cur, e, client, passed)
	chain.Emit("GovNotice", "client", client, "epoch", strconv.FormatUint(uint64(e), 10), "status", "applied")
}

// retireForGov retires the gno client c for governance: for good if a route
// replacement retired it for transfers, otherwise for the gov port.
func retireForGov(cur realm, c string) {
	rd, _ := transfer.ExtView("controls").(controls.Reader)
	switch {
	case core.IsClientRetired(c):
	case rd.Valid() && rd.RetiredRouteOf(c) != "":
		core.RetireClient(cross(cur), c)
	case !core.IsClientRetiredFor(c, GovPort):
		core.RetireClientPort(cross(cur), c, GovPort)
	}
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
	// A duplicate answering a re-send of a decision already acknowledged
	// otherwise changes nothing: the earlier status stands.
	if status == StatusDuplicate && d.status != 0 && d.status != StatusDuplicate {
		d.redispatch = current && redispatch
		d.event = "acknowledged: duplicate of a decision " + statusWord(d.status)
		chain.Emit("GovAck", "epoch", strconv.FormatUint(uint64(d.epoch), 10), "seq", u64s(d.seq), "status", statusWord(status))
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
	// the router client the decision names, and the scope it must be in
	// (checkRouterClient), checked again here: an epoch switch between a
	// request and its recording moves the route's router client
	client string
	scope  int
	// a kind 10: the transition it makes Ethereum expect, recorded here
	// when it is dispatched (router client ids), and the local gno client
	// approved to carry the epoch over the new one
	from, to, local string
}

func (p *ethParams) apply(cur realm, t int64) (string, string) {
	if p.epoch != 0 && p.epoch != epoch {
		return "", "the cancel names numbers of epoch " + strconv.FormatUint(uint64(p.epoch), 10) + ", which is past"
	}
	if refusal := checkRouterClient(p.client, p.scope); refusal != "" {
		return "", refusal
	}
	if p.to != "" {
		if refusal := checkExpect(p.from, p.to, p.local); refusal != "" {
			return "", refusal
		}
	}
	seq, refusal := bind(cur, ledger.Last(), p.kind, p.params)
	if refusal != "" {
		return "", refusal
	}
	note := "dispatched as epoch " + strconv.FormatUint(uint64(epoch), 10) + " seq " + u64s(seq)
	if p.to != "" {
		// The packet goes at once; approving the local client to carry the
		// epoch loosens, so the expectation is a decision of its own that
		// waits 7 days and that a hold defers, as for an emergency recovery
		// (NewExpectRecoveryRequest). A notice over it before then is
		// refused, and IBCAdmin sends it again.
		text := "expect the governance epoch to move from " + p.from + " to " + p.to + ", carried here by " + p.local + " (kind 10)"
		ep := &expectParams{from: p.from, to: p.to, local: p.local}
		d := decide(cur, "expect transition", text, ep, t, t, true)
		ep.owner = d.ID
		ep.gen = intend(p.from, p.to, p.local, d.ID)
		note += "; its transition is expected from decision " + itoa(d.ID)
	}
	return note, ""
}

func ethRequest(cur realm, name string, kind uint8, text string, params []byte) Request {
	return ethRequestIn(cur, name, kind, text, params, 0)
}

func ethRequestIn(cur realm, name string, kind uint8, text string, params []byte, bound uint32) Request {
	return ethRequestP(cur, name, text, &ethParams{kind: kind, params: params, epoch: bound})
}

// ethRouteParams is the parameters of a decision naming the router client
// clientID in scope, checked now (a refusal panics) and again when the
// decision is recorded; the builder adds the encoded params.
func ethRouteParams(kind uint8, clientID string, scope int) *ethParams {
	mustEthClientID(clientID)
	if refusal := checkRouterClient(clientID, scope); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	return &ethParams{kind: kind, client: clientID, scope: scope}
}

func ethRequestP(cur realm, name, text string, p *ethParams) Request {
	kind, params := p.kind, p.params
	if epochRecOf(epoch) == nil {
		panic("ibcgov: the governance channel is not bound")
	}
	if envelopeHeader+len(params) > MaxEnvelope {
		panic("ibcgov: the envelope would be " + strconv.Itoa(envelopeHeader+len(params)) + " bytes, above " + strconv.Itoa(MaxEnvelope))
	}
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

// The scope a decision's router client id must be in. A clientId on the
// wire is the Ethereum router's, never this chain's (ADR pr6375 §5.4), and
// this chain knows the pairing: the counterparty the core registered for
// each of its Ethereum clients. A decision naming this chain's own client
// of the route, which the router's grammar admits, would be recorded on
// Ethereum under a route key nothing uses, so every id is checked against
// the pairing, when the request is built and when it is recorded.
const (
	noRouterClient = iota
	// currentRouterClient is the router's current client of the route:
	// the epoch client's counterparty, which the binding and every epoch
	// notice since established. Ethereum keys the route by it, and an
	// epoch switch abandons the decisions of the epoch before, so no other
	// id names the route (kinds 2, 4, 5, 11, 13).
	currentRouterClient
	// lineageRouterClient is a router client of the route, current or
	// retired by a replacement: what a kind 12 settles. Ethereum refuses
	// one it has not retired, which this chain cannot always tell, as its
	// own replacement and the notice of Ethereum's may lag either way.
	lineageRouterClient
	// knownRouterClient is any router client this realm pairs with a
	// governed client of this chain: the lineage, the epoch's, and every
	// successor an expected transition or tombstone names (kind 6 op 2).
	knownRouterClient
)

// routeRouterClient is the Ethereum router's current client of the route
// the governance channel serves.
func routeRouterClient() string { return core.CounterpartyClientID(EpochClient()) }

// routeLineage is every router client a client of the enrolled route is
// paired with: its current client's and those of the clients replacements
// retired from it.
func routeLineage() []string {
	rd := view()
	var ids []string
	for _, key := range rd.Routes() {
		for _, c := range append([]string{rd.Client(key)}, rd.Replaced(key)...) {
			if cp := core.CounterpartyClientID(c); cp != "" {
				ids = append(ids, cp)
			}
		}
	}
	return ids
}

// routerClients is every router client this realm pairs with a governed
// client of this chain (knownRouterClient).
func routerClients() []string {
	ids := routeLineage()
	remotes, _ := retained()
	for id := range remotes {
		if !contains(ids, id) {
			ids = append(ids, id)
		}
	}
	return ids
}

// checkRouterClient is why clientID cannot name a router client in scope,
// or "": a client of this chain named in its place is told the router
// client it is paired with, the id that was meant.
func checkRouterClient(clientID string, scope int) string {
	if scope == noRouterClient {
		return ""
	}
	if epoch == 0 {
		return "the governance channel is not bound"
	}
	var ids []string
	var what string
	switch scope {
	case currentRouterClient:
		ids, what = []string{routeRouterClient()}, "the Ethereum router's current client of the route, "
	case lineageRouterClient:
		ids, what = routeLineage(), "an Ethereum router client of the route, current or retired: "
	default:
		ids, what = routerClients(), "an Ethereum router client this realm pairs with a client of this chain: "
	}
	if contains(ids, clientID) {
		return ""
	}
	return clientID + " is not " + what + strings.Join(ids, ", ") + gnoClientHint(clientID)
}

// gnoClientHint names, after a refusal of id as a router client id, the
// router client it is paired with when it is a client of this chain: the
// mistake these checks catch is naming this chain's client of the route
// where the router's goes.
func gnoClientHint(id string) string {
	if core.ClientType(id) == "" {
		return ""
	}
	if cp := core.CounterpartyClientID(id); cp != "" {
		return "; " + id + " is this chain's client, paired with " + cp
	}
	return "; " + id + " is this chain's client, with no counterparty registered"
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
// at most 14, what the 1024-byte envelope holds), each within the numbers
// already dispatched. IBCAdmin applies
// it at recording, whatever its own seq. It is spent if a route replacement
// opens another epoch before it is recorded.
func NewEthCancelRequest(cur realm, ranges string) Request {
	items := splitList(ranges)
	if len(items) == 0 || len(items) > maxCancelRanges {
		panic("ibcgov: name 1 to " + strconv.Itoa(maxCancelRanges) + " ranges: no more fit the 1024-byte envelope")
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
// there: object 1 is the transfer route, named by its router client
// clientID (currentRouterClient), object 2 IBCAdmin itself (clientID
// empty).
func NewEthUnpauseRequest(cur realm, object int, clientID string) Request {
	var p *ethParams
	switch object {
	case 1:
		p = ethRouteParams(KindUnpause, clientID, currentRouterClient)
	case 2:
		if clientID != "" {
			panic("ibcgov: object 2 (IBCAdmin) names no client")
		}
		p = &ethParams{kind: KindUnpause}
	default:
		panic("ibcgov: object 1 (a transfer route) or 2 (IBCAdmin)")
	}
	p.params = abi.Encode(abi.Uint64(uint64(object)), abi.String(clientID))
	return ethRequestP(cur, "unpause", "unpause object "+strconv.Itoa(object)+" "+clientID, p)
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

// NewEthLimitsRequest (kind 4) sets a token's limits on the route, named by
// its router client clientID (currentRouterClient): per-message maximum,
// day cap, refund cap, and for Ethereum-native tokens the send maximum and
// minimum (0 unset), in base units as decimal digits. IBCAdmin applies a
// pure lowering at recording, anything else after 7 days.
func NewEthLimitsRequest(cur realm, clientID, token, maxPerMessage, dayCap, refundCap, sendMax, sendMin string) Request {
	p := ethRouteParams(KindLimits, clientID, currentRouterClient)
	tok := mustEthAddr(token)
	p.params = abi.Encode(abi.String(clientID), abi.Address(tok),
		mustUint256("maxPerMessage", maxPerMessage), mustUint256("dayCap", dayCap), mustUint256("refundCap", refundCap),
		mustUint256("sendMax", sendMax), mustUint256("sendMin", sendMin))
	text := "limits of " + ethAddrText(tok) + " on " + clientID + ": maxPerMessage=" + maxPerMessage + " dayCap=" + dayCap +
		" refundCap=" + refundCap + " sendMax=" + sendMax + " sendMin=" + sendMin
	return ethRequestP(cur, "limits", text, p)
}

// NewEthVoucherRequest (kind 5) registers the GnoVoucher of a gno denom on
// the route, named by its router client clientID (currentRouterClient),
// pinned to its code hash (setCustomERC20). baseDenom is the denom as the
// transfer app puts it on the wire (isGnoWireDenom): a native denom, or a
// GRC20 alias; a realm-issued coin ("/gno.land/r/...:x") never travels and
// is refused.
func NewEthVoucherRequest(cur realm, clientID, baseDenom, voucher, codeHash string) Request {
	p := ethRouteParams(KindVoucher, clientID, currentRouterClient)
	if !isGnoWireDenom(baseDenom) {
		panic("ibcgov: not a gno.land denom the transfer app sends: " + baseDenom)
	}
	v, h := mustEthAddr(voucher), mustHash(codeHash)
	p.params = abi.Encode(abi.String(clientID), abi.String(baseDenom), abi.Address(v), abi.Bytes32(h))
	text := "voucher of " + baseDenom + " on " + clientID + ": " + ethAddrText(v) + " code hash " + hex.EncodeToString(h[:])
	return ethRequestP(cur, "voucher", text, p)
}

// NewEthClientRequest (kind 6) adds (op 1) or migrates (op 2) a router light
// client: clientID is the router's client id, counterpartyClientID the gno
// client it tracks (op 1), merklePrefix a comma-separated list of hex items,
// lightClient the contract and codeHash its code hash. Op 1 adds the custom
// id that the gno client is paired with (its registered counterparty); op
// 2 names a router client this realm pairs with a governed client
// (knownRouterClient).
func NewEthClientRequest(cur realm, op int, clientID, counterpartyClientID, merklePrefix, lightClient, codeHash string) Request {
	var p *ethParams
	switch op {
	case 1:
		mustCustomEthClientID(clientID)
		if core.ClientType(counterpartyClientID) == "" {
			panic("ibcgov: the counterparty " + counterpartyClientID + " is not a gno client")
		}
		if cp := core.CounterpartyClientID(counterpartyClientID); cp != clientID {
			if cp == "" {
				cp = "no router client yet"
			}
			panic("ibcgov: the gno client " + counterpartyClientID + " is paired with " + cp + ", not " + clientID)
		}
		p = &ethParams{kind: KindClient}
	case 2:
		p = ethRouteParams(KindClient, clientID, knownRouterClient)
		if counterpartyClientID != "" {
			mustEthClientID(counterpartyClientID)
		}
	default:
		panic("ibcgov: op 1 (add) or 2 (migrate)")
	}
	var prefix []abi.Value
	var prefixText []string
	for _, item := range strings.Split(merklePrefix, ",") {
		b := mustHexBytes(strings.TrimSpace(item))
		prefix = append(prefix, abi.Bytes(b))
		prefixText = append(prefixText, hex.EncodeToString(b))
	}
	lc, h := mustEthAddr(lightClient), mustHash(codeHash)
	p.params = abi.Encode(abi.Uint64(uint64(op)), abi.String(clientID), abi.String(counterpartyClientID), abi.Array(prefix...), abi.Address(lc), abi.Bytes32(h))
	text := "client op " + strconv.Itoa(op) + " " + clientID + " counterparty " + counterpartyClientID + " prefix [" +
		strings.Join(prefixText, ",") + "] light client " + ethAddrText(lc) + " code hash " + hex.EncodeToString(h[:])
	return ethRequestP(cur, "client", text, p)
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
// its code hash. It only moves the executor pin: any migration is the new
// executor's own, done afterwards through its own decisions. The migration
// call field stays on the wire, always empty: Ethereum spends a kind 9 that
// carries one at recording.
func NewEthHandOverRequest(cur realm, exec, codeHash string) Request {
	e, h := mustEthAddr(exec), mustHash(codeHash)
	text := "hand over to " + ethAddrText(e) + " code hash " + hex.EncodeToString(h[:])
	return ethRequest(cur, "hand-over", KindHandOver, text, abi.Encode(abi.Address(e), abi.Bytes32(h), abi.Bytes([]byte{})))
}

// NewEthRouteReplacementRequest (kind 10) retires and freezes the router
// client oldClientID, migrates its route to newClientID (a custom id added by
// kind 6 first) and opens IBCAdmin's next epoch over it. suspectFrom is the
// Ethereum block from which acknowledgements and timeouts processed through
// the old client are suspect (ADR pr6375 §5.4, §7.12): every send record
// processed at or after it must be settled by kind 12 before kind 13 reopens
// the route. localClientID is the gno.land Ethereum client approved to carry
// the governance epoch over newClientID once IBCAdmin's epoch notice
// arrives (Active, not retired, its counterparty newClientID, authenticating
// the governance route's identity, checked again when it is dispatched):
// the notice is accepted over that client only.
func NewEthRouteReplacementRequest(cur realm, oldClientID, newClientID string, suspectFrom uint64, localClientID string) Request {
	mustEthClientID(oldClientID)
	mustCustomEthClientID(newClientID)
	if oldClientID == newClientID {
		panic("ibcgov: the clients differ")
	}
	if refusal := checkExpect(oldClientID, newClientID, localClientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	return ethRequestP(cur, "route replacement", "replace route "+oldClientID+" by "+newClientID+" (carried here by "+localClientID+"), suspect from Ethereum block "+u64s(suspectFrom),
		&ethParams{kind: KindRouteReplace, params: abi.Encode(abi.String(oldClientID), abi.String(newClientID), abi.Uint64(suspectFrom)), from: oldClientID, to: newClientID, local: localClientID})
}

// expectParams records an expected governance transition.
type expectParams struct {
	from, to, local string
	owner           int64  // this expectation's decision, an owner of its intent
	gen             uint64 // the intent's generation it owns
}

func (p *expectParams) apply(cur realm, t int64) (string, string) {
	// It applies only to its own intent, still pending: an epoch switch
	// that left the transition behind dropped it, and an approval of it is
	// then stale.
	if !ownsIntent(p.from, p.to, p.local, p.gen, p.owner) {
		disown(p.from, p.to, p.local, p.gen, p.owner)
		return "", "its intent is gone (an epoch switch left the transition behind, or it was released)"
	}
	if refusal := checkExpect(p.from, p.to, p.local); refusal != "" {
		release(p.from, p.to, p.local, p.gen, p.owner)
		return "", refusal
	}
	disown(p.from, p.to, p.local, p.gen, p.owner)
	expect(p.from, p.to, p.local)
	return "expect the governance epoch to move from " + p.from + " to " + p.to + " over " + p.local, ""
}

// removeParams removes an active expected transition.
type removeParams struct{ from, to, local string }

func (p *removeParams) apply(cur realm, t int64) (string, string) {
	if refusal := checkRemove(p.from, p.to, p.local); refusal != "" {
		return "", refusal
	}
	entomb(p.from, p.to, p.local) // in its place: its client stays retained
	var kept []expEdge
	for _, x := range expectedOf(p.from) {
		if !(x.active && x.to == p.to && x.local == p.local) {
			kept = append(kept, x)
		}
	}
	setEdges(p.from, kept)
	liveEdges--
	chain.Emit("GovUnexpect", "from", p.from, "to", p.to, "client", p.local)
	return "no longer expect the governance epoch to move from " + p.from + " to " + p.to + " over " + p.local, ""
}

// checkRemove is why the active transition from → to over local cannot be
// removed, or "": it must be active (a pending one goes with its
// expectations, cancelled), not lead to the epoch's own client, and lie on
// no path a notice recorded as proven may still be applied along (see
// pinnedBy: a notice its client no longer vouches for, or with no path of
// the length it needs through the transition, pins nothing). It needs no
// room: its tombstone takes its place in the joint budget.
func checkRemove(from, to, local string) string {
	found := false
	for _, x := range expectedOf(from) {
		if x.active && x.to == to && x.local == local {
			found = true
		}
	}
	if !found {
		return "no active expected transition from " + from + " to " + to + " over " + local
	}
	if local == EpochClient() {
		return local + " carries the governance epoch"
	}
	if c := pinnedBy(from, to, local, false); c != "" {
		return "a notice proven over " + c + " may need the transition: apply it or let it lapse first"
	}
	return ""
}

// retransmitParams authorizes one re-send of a conflicted dispatch.
type retransmitParams struct {
	e   uint32
	seq uint64
}

// checkRetransmit is why dispatch (e, seq) cannot be authorized for a
// re-send after a conflict, or "".
func checkRetransmit(e uint32, seq uint64) string {
	d := dispatchOf(e, seq)
	switch {
	case d == nil:
		return "no dispatched decision " + strconv.FormatUint(uint64(e), 10) + "/" + u64s(seq)
	case e != epoch:
		return "epoch " + strconv.FormatUint(uint64(e), 10) + " is past: its decisions are never sent again"
	case d.status != StatusConflict || d.redispatch:
		return "decision " + u64s(seq) + " was not answered with a conflict that bars a re-send (" + d.event + ")"
	case d.retransmit:
		return "decision " + u64s(seq) + " is authorized for a re-send already"
	}
	return ""
}

func (p *retransmitParams) apply(cur realm, t int64) (string, string) {
	if refusal := checkRetransmit(p.e, p.seq); refusal != "" {
		return "", refusal
	}
	d := dispatchOf(p.e, p.seq)
	d.retransmit = true
	d.event += "; one re-send authorized"
	return "authorize one re-send of epoch " + strconv.FormatUint(uint64(p.e), 10) + " seq " + u64s(p.seq) + ": anyone calls Redispatch", ""
}

// NewRetransmitRequest authorizes, at once, one re-send of dispatch (e,
// seq) of the current epoch that IBCAdmin answered with a conflict and no
// redispatch, whose re-send Redispatch otherwise refuses (ADR 0004: a
// deliberate addition to ADR pr6375 §5.4). Governance decides it after
// checking on Ethereum that the conflict was fabricated: IBCAdmin holds no
// decision at that seq, or holds these very bytes, and emitted no Conflict
// for it. It is no loosening: the bytes are immutable and IBCAdmin
// deduplicates them, so the re-send records the decision if it was never
// delivered and is answered duplicate if it was. It is used up by one
// Redispatch; another needs another decision.
func NewRetransmitRequest(cur realm, e uint32, seq uint64) Request {
	if refusal := checkRetransmit(e, seq); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	text := "authorize one re-send of the conflicted governance dispatch, epoch " + strconv.FormatUint(uint64(e), 10) + " seq " + u64s(seq)
	return propose(cur, "retransmit", text, func(cur realm, made, t int64) {
		decide(cur, "retransmit", text, &retransmitParams{e: e, seq: seq}, made, t, false)
	})
}

// purgeParams drops a tombstone.
type purgeParams struct{ from, to, local string }

// checkPurge is why the tombstone of the transition from → to over local
// cannot be purged, or "": it must exist, and lie on no path a notice
// recorded as proven may still be applied along once the transitions on it
// are approved again (pinnedBy through live and tombstoned transitions).
func checkPurge(from, to, local string) string {
	if !tombstones.Has(tombKey(from, to, local)) {
		return "no tombstone of the transition from " + from + " to " + to + " over " + local
	}
	if c := pinnedBy(from, to, local, true); c != "" {
		return "a notice proven over " + c + " may need the transition: approve it again and apply the notice, or let it lapse first"
	}
	return ""
}

func (p *purgeParams) apply(cur realm, t int64) (string, string) {
	if refusal := checkPurge(p.from, p.to, p.local); refusal != "" {
		return "", refusal
	}
	// A purge only frees capacity: it never makes a client retirable. The
	// clients it disconnects (no longer reachable, though no switch passed
	// them) leave awaitingGov, so no prune retires them: they stay as
	// clients kept off the graph, their gov port open and inert, retired for
	// governance only by a switch leaving them as its old epoch client. Bounded: two walks of at
	// most maxLive edges.
	_, before := retained()
	tombstones.Remove(tombKey(p.from, p.to, p.local))
	_, after := retained()
	for c := range before {
		if !after[c] && awaitingGov.Has(c) {
			awaitingGov.Remove(c)
		}
	}
	chain.Emit("GovPurge", "from", p.from, "to", p.to, "client", p.local)
	return "purged the tombstone of the transition from " + p.from + " to " + p.to + " over " + p.local, ""
}

// NewPurgeTombstoneRequest drops, after 7 days (deferred by a hold), the
// tombstone a removed or released transition from the router client
// oldClientID to newClientID over the gno client localClientID left (ADR
// 0004: a deliberate addition), freeing its place in the joint budget of
// maxLive without an epoch switch. It frees capacity only: the local
// client, and those of the transitions beyond it, are no longer held by the
// graph, but none becomes retirable by it: they are kept off the graph,
// their gov port open and inert, until a switch passes them; if Ethereum did
// execute the transition, it must be expected again for its notice to apply.
// Refused, when built and when it applies, while a notice recorded as
// proven may still be applied along a path through it of the length it
// needs, its transitions approved again.
func NewPurgeTombstoneRequest(cur realm, oldClientID, newClientID, localClientID string) Request {
	if refusal := checkPurge(oldClientID, newClientID, localClientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	text := "purge the tombstone of the transition from " + oldClientID + " to " + newClientID + " over " + localClientID
	return propose(cur, "purge tombstone", text, func(cur realm, made, t int64) {
		decide(cur, "purge tombstone", text, &purgeParams{from: oldClientID, to: newClientID, local: localClientID}, made, t, true)
	})
}

// NewRemoveExpectationRequest removes, at once, the active expected
// transition from the router client oldClientID to newClientID over the gno
// client localClientID (ADR 0004: a deliberate addition to ADR pr6375
// §7.12). It tightens: it narrows what a notice may authorize, and frees its
// place among the old client's successors and the graph's 64, so
// governance can drop a transition Ethereum cancelled or never executed. A
// transition Ethereum did execute costs only liveness if removed: it is
// expected again through the 7-day expectation. Refused for the transition
// to the epoch's own client, and while a notice recorded as proven may still
// be applied along a path through it of exactly the steps the notice needs:
// a notice whose client is frozen, expired, recovered, converted or retired,
// whose epoch the current one reached, or with no such path through the
// transition, pins nothing.
func NewRemoveExpectationRequest(cur realm, oldClientID, newClientID, localClientID string) Request {
	if refusal := checkRemove(oldClientID, newClientID, localClientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	text := "remove the expected transition from " + oldClientID + " to " + newClientID + " over " + localClientID
	return propose(cur, "remove expectation", text, func(cur realm, made, t int64) {
		decide(cur, "remove expectation", text, &removeParams{from: oldClientID, to: newClientID, local: localClientID}, made, t, false)
	})
}

// NewExpectRecoveryRequest records, after 7 days, that Ethereum's emergency
// recovery is to move the governance epoch from the router client
// oldClientID to newClientID (ADR pr6375 §7.12): ibcgov dispatches no
// emergency recovery, so this decision is what lets the recovery's epoch
// notice be accepted, over localClientID only (checked as for a kind 10,
// and again when it executes). Approving a local verifier loosens, so it
// waits 7 days and a guardian hold defers it, within Ethereum's own 30-day
// recovery delay.
// An expectation never confirmed by a notice costs nothing; a router client
// has at most 4 expected successors.
func NewExpectRecoveryRequest(cur realm, oldClientID, newClientID, localClientID string) Request {
	mustEthClientID(oldClientID)
	mustCustomEthClientID(newClientID)
	if oldClientID == newClientID {
		panic("ibcgov: the clients differ")
	}
	if refusal := checkExpect(oldClientID, newClientID, localClientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	text := "expect the emergency recovery of " + oldClientID + " by " + newClientID + ", carried here by " + localClientID
	return propose(cur, "expect recovery", text, func(cur realm, made, t int64) {
		// Fresh parameters for every recording: a Request governed twice
		// makes two decisions, each owning its own place in the intent.
		p := &expectParams{from: oldClientID, to: newClientID, local: localClientID}
		// An intent from the recording on: it holds the successor's place
		// and keeps its clients open for governance.
		// Refused when recorded (the graph changed since the request was
		// built): a spent decision, no intent, so an approved proposal is
		// used up rather than left to execute again once room frees.
		if refusal := checkExpect(oldClientID, newClientID, localClientID); refusal != "" {
			spendAtRecording("expect recovery", text, p, made, t, refusal)
			return
		}
		d := decide(cur, "expect recovery", text, p, made, t, true)
		p.owner = d.ID
		p.gen = intend(oldClientID, newClientID, localClientID, d.ID)
	})
}

// NewEthRouteSettingsRequest (kind 11) sets the quarantine of the route,
// named by its router client clientID (currentRouterClient), after a
// validator-set transition, in seconds (0 disables it).
func NewEthRouteSettingsRequest(cur realm, clientID string, quarantineSeconds uint64) Request {
	p := ethRouteParams(KindRouteSettings, clientID, currentRouterClient)
	p.params = abi.Encode(abi.String(clientID), abi.Uint64(quarantineSeconds))
	return ethRequestP(cur, "route settings", "quarantine of "+clientID+": "+u64s(quarantineSeconds)+" s", p)
}

// NewEthSettleRequest (kind 12) applies a reconciliation's outcomes to the
// send records of clientId, the router client a route replacement retired
// (ADR pr6375 §5.4, §7.12; lineageRouterClient): items is a comma-separated
// list of "sequence:action:amount" (amount in base units as decimal
// digits), at most 8, each sequence once:
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
	p := ethRouteParams(KindSettle, clientID, lineageRouterClient)
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
	p.params = abi.Encode(abi.String(clientID), abi.Array(vals...))
	return ethRequestP(cur, "settle", "settle sends of "+clientID+": "+strings.Join(list, ","), p)
}

// NewEthReopenRequest (kind 13) reopens the route, named by its router
// client clientID (currentRouterClient), that a route replacement or the
// emergency recovery closed (ADR pr6375 §5.4). IBCAdmin applies it after 7
// days; Ethereum refuses it while any send record of the route's retired
// client ids is open, and records every loss not recapitalized as an
// accepted deficit.
func NewEthReopenRequest(cur realm, clientID string) Request {
	p := ethRouteParams(KindReopen, clientID, currentRouterClient)
	p.params = abi.Encode(abi.String(clientID))
	return ethRequestP(cur, "reopen", "reopen the route of "+clientID, p)
}

// isGnoWireDenom is the grammar of a gno.land denom as the transfer app puts
// it on the wire, which IBCAdmin's kind 5 must accept exactly
// (canonicalGnoDenom), at most 128 bytes:
//   - a native denom: [a-z][a-z0-9]{2,15} (e.g. ugnot);
//   - a GRC20 alias, the grc20reg key "<realm path>[.<slug>]" with "/" as
//     ":": "gno.land:r" then at least two ":"-separated path segments, each a
//     gno package name ([a-z][a-z0-9]*, with "_" or "-" only between
//     alphanumerics: "my-org", not "my--org" or "org-"), then optionally "."
//     and a slug of 1 to 32 characters of [A-Za-z0-9_-].
//
// A realm-issued coin ("/gno.land/r/...:denom") is no wire denom: the
// transfer app looks it up as a grc20reg key and sends it only as a GRC20.
func isGnoWireDenom(s string) bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	const head = "gno.land:r"
	if !strings.HasPrefix(s, head+":") {
		if len(s) < 3 || len(s) > 16 || !lowerByte(s[0]) {
			return false
		}
		for i := 1; i < len(s); i++ {
			if !lowerByte(s[i]) && !digitByte(s[i]) {
				return false
			}
		}
		return true
	}
	rest := s[len(head):]
	slug := ""
	if i := strings.IndexByte(rest, '.'); i >= 0 {
		rest, slug = rest[:i], rest[i+1:]
		if len(slug) == 0 || len(slug) > 32 {
			return false
		}
		for i := 0; i < len(slug); i++ {
			c := slug[i]
			if !lowerByte(c) && !digitByte(c) && !(c >= 'A' && c <= 'Z') && c != '_' && c != '-' {
				return false
			}
		}
	}
	segs := strings.Split(rest[1:], ":")
	if len(segs) < 2 {
		return false
	}
	for _, seg := range segs {
		if !isPkgName(seg) {
			return false
		}
	}
	return true
}

// isPkgName is gno's package path segment grammar (gnolang Re_name):
// [a-z][a-z0-9]*([_-][a-z0-9]+)*.
func isPkgName(seg string) bool {
	if len(seg) == 0 || !lowerByte(seg[0]) {
		return false
	}
	for i := 1; i < len(seg); i++ {
		c := seg[i]
		switch {
		case lowerByte(c) || digitByte(c):
		case c == '_' || c == '-':
			if i+1 >= len(seg) || !(lowerByte(seg[i+1]) || digitByte(seg[i+1])) {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func lowerByte(c byte) bool { return c >= 'a' && c <= 'z' }
func digitByte(c byte) bool { return c >= '0' && c <= '9' }
