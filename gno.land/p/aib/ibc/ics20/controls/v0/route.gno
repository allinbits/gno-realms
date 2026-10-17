// Package controls is the state of the safety controls an ICS-20 transfer
// app keeps for its Ethereum routes (ADR pr6375 §7.1, §7.8, §7.9, §7.12,
// §7.13): per route and denom, the outflow meters and the claim queue that
// pays credits from Ethereum, the sweep queue, the send limits, the immutable
// per-packet send records with the refund meter and the queued refunds, the
// voids and restores, and the loss ledger with its recapitalizations,
// reductions and accepted deficits.
//
// It holds no coins and makes no call: the transfer implementation moves
// value as the Payment values returned here say, through the transfer proxy's
// services, and decides what a refusal means (an error acknowledgement before
// any state change, or a spent decision). Every function validates first and
// mutates only once nothing can fail, so an error leaves the state untouched.
// Clocks are unix seconds and block heights, passed in.
//
// A Registry lives in the transfer proxy's storage, allocated there through
// NewRegistryAny; only the proxy's gated accessor hands out the pointer, to
// the active implementation. Other realms read it through a Reader, which
// exposes no mutator.
//
// The meter, claim, installment and void algorithms are ported from
// gnolang/bridges (branch ethereum-draft, commit a58efe81c9eb):
// solana/realm/p/hlroute/v0/hlroute.gno (Meter, Credit, Claim, void,
// restore) and ethereum/realm/hlgnot/installments.gno (no slivers),
// Copyright (C) 2026 NewTendermint, LLC, under the GNO Network General Public
// License. They are adapted to IBC: claims are keyed by packet, a route holds
// several denoms with two accountings (unescrow and mint), and refunds have
// their own meter.
package controls

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/aib/encoding/ethaddr/v0"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	// Day is a day of block time, in seconds.
	Day = int64(86400)
	// MaxClaims is the most claims one Claim call pays (ADR pr6375 §7.1).
	MaxClaims = 20
	// ReopenBatch is how many incidents, then authorizations, one batch of
	// a reopening looks at.
	ReopenBatch = 64
	// MaxKeys is the most packet keys one decision names.
	MaxKeys = 64
	// PageLines is how many entries a page lists.
	PageLines = 100

	maxInt64 = int64(1<<63 - 1)
)

// Claim states.
const (
	Open     = "open"     // credited, unpaid or paying
	Withheld = "withheld" // voided as withheld: the remainder stays booked, restorable
	Forged   = "forged"   // voided as forged: the remainder dropped, the paid part lost
	Done     = "done"     // paid in full
)

// Who credited a claim.
const (
	ByPacket = "packet" // a received packet
	ByVote   = "vote"   // a credit-by-vote decision
)

// PacketKey is the key of a packet on a client: the client id, "/", and the
// sequence in 20 decimal digits, so keys sort by sequence.
func PacketKey(clientID string, sequence uint64) string {
	s := strconv.FormatUint(sequence, 10)
	return clientID + "/" + strings.Repeat("0", 20-len(s)) + s
}

// ParsePacketKey splits a packet key; ok is false for anything else,
// including a client part that is not a valid client identifier.
func ParsePacketKey(key string) (clientID string, sequence uint64, ok bool) {
	i := strings.LastIndex(key, "/")
	if i <= 0 || len(key)-i-1 != 20 {
		return "", 0, false
	}
	if host.ClientIdentifierValidator(key[:i]) != nil {
		return "", 0, false
	}
	seq, err := strconv.ParseUint(key[i+1:], 10, 64)
	if err != nil || seq == 0 {
		return "", 0, false
	}
	return key[:i], seq, true
}

func seqKey(n int64) string {
	s := strconv.FormatInt(n, 10)
	return strings.Repeat("0", 19-len(s)) + s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// ---------------------------------------------------------------- registry

// Registry holds the controlled routes and the client aliases: a route is
// keyed by a stable route key (its first client id), and its current client
// id is an alias, so a route replacement re-points the alias in constant work
// (ADR pr6375 §7.12, R18).
type Registry struct {
	routes  avl.Tree // route key -> *Route
	aliases avl.Tree // current client id -> route key
	retired avl.Tree // retired client id -> route key
}

// NewRegistry is an empty registry.
func NewRegistry() *Registry { return &Registry{} }

// NewRegistryAny is NewRegistry for a constructor slot typed func() any.
func NewRegistryAny() any { return NewRegistry() }

// Enroll creates the route key, whose current client is key itself, at block
// time now and height: the route's activation, before which no receive was
// booked under its controls.
func (r *Registry) Enroll(key string, collector address, now, height int64) (*Route, error) {
	if key == "" {
		return nil, errors.New("controls: empty route key")
	}
	if !collector.IsValid() {
		return nil, errors.New("controls: invalid fee collector " + string(collector))
	}
	if r.routes.Has(key) || r.aliases.Has(key) || r.retired.Has(key) {
		return nil, errors.New("controls: client " + key + " is a route or a route's client already")
	}
	rt := &Route{Key: key, Client: key, Enrolled: now, Activated: height, FeeCollector: collector}
	r.routes.Set(key, rt)
	r.aliases.Set(key, key)
	return rt, nil
}

// Route is the route with this key, or nil.
func (r *Registry) Route(key string) *Route {
	v := r.routes.Get(key)
	if v == nil {
		return nil
	}
	return v.(*Route)
}

// RouteOf is the route whose current client is clientID, or nil.
func (r *Registry) RouteOf(clientID string) *Route {
	v := r.aliases.Get(clientID)
	if v == nil {
		return nil
	}
	return r.Route(v.(string))
}

// RetiredRouteOf is the key of the route a replacement retired clientID from,
// or "".
func (r *Registry) RetiredRouteOf(clientID string) string {
	v := r.retired.Get(clientID)
	if v == nil {
		return ""
	}
	return v.(string)
}

// Replace re-points the route key to newClient (ADR pr6375 §7.12): newClient
// becomes the route's current client and the old one is retired. Nothing per
// denom moves: escrow, vouchers and controls stay keyed by the route key. The
// route closes in the same step (no send, credit, claim payout or refund
// payout) until a governed reopening, once the reconciliation's losses all
// have a restoring decision (Reopen).
func (r *Registry) Replace(key, newClient string, suspectFrom, height int64) error {
	rt := r.Route(key)
	if rt == nil {
		return errors.New("controls: no route " + key)
	}
	if suspectFrom < 0 {
		return errors.New("controls: a negative suspect height")
	}
	// One replacement at a time, as on Ethereum: the previous one's
	// reconciliation and reopening come first.
	if rt.Closed || rt.Reopening {
		return errors.New("controls: route " + key + " is still closed from its previous replacement")
	}
	// The old client became current at the previous replacement: its suspect
	// interval never starts before it (records before were reconciled then).
	if suspectFrom < rt.ReplacedAt {
		suspectFrom = rt.ReplacedAt
	}
	if newClient == "" || r.aliases.Has(newClient) || r.retired.Has(newClient) || r.routes.Has(newClient) {
		return errors.New("controls: client " + newClient + " is a route's client already")
	}
	old := rt.Client
	r.aliases.Remove(old)
	r.retired.Set(old, key)
	r.aliases.Set(newClient, key)
	rt.Client = newClient
	rt.Replaced = append(rt.Replaced, old)
	rt.suspect.Set(old, suspectFrom)
	rt.ReplacedAt = height
	rt.Closed = true
	return nil
}

// Keys lists the route keys.
func (r *Registry) Keys() []string {
	var out []string
	r.routes.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// ReadOnly is the registry's read-only view (see Reader).
func (r *Registry) ReadOnly() any { return Reader{r: r} }

// ------------------------------------------------------------------- route

// Route is the controls state of one route.
type Route struct {
	Key          string
	Client       string   // the current client id
	Replaced     []string // the client ids replacements retired, oldest first
	Enrolled     int64    // block time of the enrolment
	Activated    int64    // block height of the enrolment: the controls' cutoff
	FeeCollector address
	Closed       bool  // closed by a replacement until a governed reopening
	Reopening    bool  // a reopening decision runs in batches (ContinueReopen)
	ReplacedAt   int64 // the block height of the last replacement

	refused   avl.Tree // lower-case Ethereum address -> true: refused send recipients
	protected avl.Tree // lower-case Ethereum address -> its role: the bridge's own contracts, never a recipient
	bridged   bool     // the router, ICS20 transfer and IBCAdmin are protected (Protect)
	denoms    avl.Tree // denom -> *Denom
	claims    avl.Tree // packet key -> *Claim
	sweeps    avl.Tree // packet key -> *SweepEntry
	sends     avl.Tree // packet key -> *SendRecord
	openSends avl.Tree // client id -> int64: its open send records
	pending   avl.Tree // client id -> int64: its send records with no outcome yet
	processed avl.Tree // client id -> *processedSet: its processed, unsettled send records by height
	suspect   avl.Tree // retired client id -> int64: the height its suspect interval starts at

	reopenIncident, reopenRecap string   // where a batched reopening stopped
	lossesBooked                int64    // every loss booked: a reopening restarts its scan when it changes
	reopenLosses                int64    // lossesBooked when the reopening's incident scan started
	losses                      avl.Tree // loss key -> *Loss
	lossIDs                     avl.Tree // lossID(direction, packet key) -> loss key: one loss per packet
	incidents                   avl.Tree // denom|incident -> *IncidentTotals
	recaps                      avl.Tree // seqKey(id) -> *Recap
	nRecaps                     int64
}

// PendingSends is how many send records of clientID have no outcome yet:
// their commitments are outstanding in the core.
func (rt *Route) PendingSends(clientID string) int64 {
	if v := rt.pending.Get(clientID); v != nil {
		return v.(int64)
	}
	return 0
}

func (rt *Route) addPending(key string, delta int64) {
	client, _, _ := ParsePacketKey(key)
	n := rt.PendingSends(client) + delta
	if n == 0 {
		rt.pending.Remove(client)
		return
	}
	rt.pending.Set(client, n)
}

// IsClosed reports whether a replacement closed the route until a governed
// reopening (ADR pr6375 §7.12): nothing moves on it, no send (voucher returns
// included), credit, claim payout or refund payout; acknowledgements and
// timeouts still settle its sends, their refunds queued.
func (rt *Route) IsClosed() bool { return rt.Closed }

// ExposureClosed reports whether the route takes on no new exposure: it is
// closed, or a loss of any denom has no restoring decision (ADR pr6375 §7.9).
// A loss stops gno-native sends, credits, claim payouts and sweep payments,
// whatever the guardians' flags; it never stops voucher returns,
// acknowledgements, timeouts or refunds, which only the refund meter and the
// refunds hold govern (§7.3, §7.13).
func (rt *Route) ExposureClosed() bool { return rt.Closed || rt.hasUnresolved() }

// LossClosed reports whether a loss of any denom has no restoring decision.
func (rt *Route) LossClosed() bool { return rt.hasUnresolved() }

// hasUnresolved reports whether any denom of the route has a loss without a
// restoring decision: denom by denom, never through a sum that could wrap.
func (rt *Route) hasUnresolved() bool {
	found := false
	rt.denoms.Iterate("", "", func(_ string, v any) bool {
		found = v.(*Denom).Totals.Unresolved() > 0
		return found
	})
	return found
}

// Reopen reopens a route a replacement closed, by decision (the gno
// analogue of Ethereum's kind 13, ADR pr6375 §5.4): refused while any send
// record of a retired client is still open (its commitment outstanding or
// its refund queued, not settled by reconciliation), or was processed (an
// acknowledgement or a timeout) at or after the replacement's suspect height
// and is not settled. Every loss not
// recapitalized or reduced is recorded as an accepted deficit by the reopening
// itself (§7.9) and every unpaid recapitalization authorization is revoked,
// in bounded batches: the route opens when the last completes (see
// ContinueReopen). It returns the deficit this batch accepted and whether the
// route is open.
func (rt *Route) Reopen() (int64, bool, error) {
	if !rt.Closed {
		return 0, false, errors.New("controls: route " + rt.Key + " is not closed")
	}
	if rt.Reopening {
		return 0, false, errors.New("controls: route " + rt.Key + " is reopening already: continue it")
	}
	if err := rt.reopenBlocker(); err != nil {
		return 0, false, err
	}
	rt.Reopening = true
	rt.reopenIncident, rt.reopenRecap = "", ""
	rt.reopenLosses = rt.lossesBooked
	return rt.reopenBatch()
}

// reopenBlocker is why the route cannot open now, or nil: a retired
// client's record is open or was processed in its suspect interval and is
// not settled.
func (rt *Route) reopenBlocker() error {
	for _, c := range rt.Replaced {
		if n := rt.OpenSends(c); n > 0 {
			return ufmt.Errorf("controls: %d send records of retired client %s are still open: settle them first", n, c)
		}
		if n := rt.SuspectUnsettled(c); n > 0 {
			return ufmt.Errorf("controls: %d send records retired client %s processed in its suspect interval are not settled: settle them first", n, c)
		}
	}
	return nil
}

// ContinueReopen runs the next bounded batch of a reopening a decision
// started (ADR pr6375 §5.4 kind 13: a permissionless continuation); the route
// opens when the last batch completes. It returns the deficit it accepted and
// whether the route is open.
func (rt *Route) ContinueReopen() (int64, bool, error) {
	if !rt.Reopening {
		return 0, false, errors.New("controls: route " + rt.Key + " is not reopening")
	}
	return rt.reopenBatch()
}

// reopenBatch records as accepted deficits the losses of at most
// ReopenBatch incidents, then revokes at most ReopenBatch unpaid
// recapitalization authorizations, from where the last batch stopped; when
// none is left the route opens.
func (rt *Route) reopenBatch() (int64, bool, error) {
	var accepted int64
	n := 0
	more := rt.incidents.Iterate(after(rt.reopenIncident), "", func(k string, v any) bool {
		if n == ReopenBatch {
			return true
		}
		it := v.(*IncidentTotals)
		if rest := it.Lost - it.Recapitalized - it.Reduced - it.Accepted; rest > 0 {
			it.Accepted = mustAdd(it.Accepted, rest)
			t := &rt.Denom(k[:strings.Index(k, "|")]).Totals
			t.Accepted = mustAdd(t.Accepted, rest)
			accepted = statAdd(accepted, rest)
		}
		rt.reopenIncident = k
		n++
		return false
	})
	if more {
		return accepted, false, nil
	}
	n = 0
	more = rt.recaps.Iterate(after(rt.reopenRecap), "", func(k string, v any) bool {
		if n == ReopenBatch {
			return true
		}
		if r := v.(*Recap); !r.Paid {
			r.Revoked = true
		}
		rt.reopenRecap = k
		n++
		return false
	})
	if more {
		return accepted, false, nil
	}
	// A loss booked since the incident scan started may sit behind its
	// cursor, on an incident it accepted already: the scan starts over, so
	// the route opens only once every incident's losses are resolved or
	// accepted (ADR pr6375 §5.4 kind 13, §7.12).
	if rt.lossesBooked != rt.reopenLosses {
		rt.reopenIncident, rt.reopenLosses = "", rt.lossesBooked
		return accepted, false, nil
	}
	rt.Reopening, rt.Closed = false, false
	return accepted, true, nil
}

// after is the first key an iteration resumes at, past cursor ("" from the
// start).
func after(cursor string) string {
	if cursor == "" {
		return ""
	}
	return cursor + "\x00"
}

// SetFeeCollector replaces the fee collector.
func (rt *Route) SetFeeCollector(a address) error {
	if !a.IsValid() {
		return errors.New("controls: invalid fee collector " + string(a))
	}
	rt.FeeCollector = a
	return nil
}

// Refuse adds lower-case Ethereum addresses to the refused send recipients
// (the route's bridge contracts, ADR pr6375 §7.8).
func (rt *Route) Refuse(addrs []string) {
	for _, a := range addrs {
		rt.refused.Set(strings.ToLower(a), true)
	}
}

// Unrefuse removes addresses from the refused send recipients.
func (rt *Route) Unrefuse(addrs []string) {
	for _, a := range addrs {
		rt.refused.Remove(strings.ToLower(a))
	}
}

// IsRefused reports whether addr (any case) is a refused send recipient: one
// a decision refused, or a protected bridge contract.
func (rt *Route) IsRefused(addr string) bool {
	a := strings.ToLower(addr)
	return rt.refused.Has(a) || rt.protected.Has(a)
}

// Bridge roles of the protected recipients.
const (
	RoleRouter       = "router"
	RoleICS20        = "ics20"
	RoleIBCAdmin     = "ibc admin"
	RoleVoucherToken = "voucher token"
)

// Protect sets the route's mandatory protected recipients, once, at its
// enrolment (ADR pr6375 R12, §7.8): its Ethereum router, ICS20 transfer
// contract and IBCAdmin, three distinct addresses (lower-case hex). They
// are never removed (Unrefuse touches only the decided refusals) and stay
// through every replacement; a route takes no gno-native send until they
// are set. Each voucher token a denom names (DenomConfig.Remote) is
// protected as it is configured.
func (rt *Route) Protect(router, ics20, ibcAdmin string) error {
	if err := CheckBridge(router, ics20, ibcAdmin); err != nil {
		return err
	}
	if rt.bridged {
		return errors.New("controls: the bridge contracts of route " + rt.Key + " are set already")
	}
	rt.protected.Set(strings.ToLower(router), RoleRouter)
	rt.protected.Set(strings.ToLower(ics20), RoleICS20)
	rt.protected.Set(strings.ToLower(ibcAdmin), RoleIBCAdmin)
	rt.bridged = true
	return nil
}

// CheckBridge is why Protect would refuse the three bridge contracts, or nil.
func CheckBridge(router, ics20, ibcAdmin string) error {
	as := []string{strings.ToLower(router), strings.ToLower(ics20), strings.ToLower(ibcAdmin)}
	for i, a := range as {
		if e, err := ethaddr.Parse(a); err != nil || e.IsZero() {
			return errors.New("controls: a bridge contract is a non-zero Ethereum address, not " + a)
		}
		for _, b := range as[:i] {
			if a == b {
				return errors.New("controls: the router, ICS20 transfer and IBCAdmin are three contracts")
			}
		}
	}
	return nil
}

// Bridged reports whether the route's bridge contracts are protected.
func (rt *Route) Bridged() bool { return rt.bridged }

// Protected lists the protected recipients as "address role".
func (rt *Route) Protected() []string {
	var out []string
	rt.protected.Iterate("", "", func(k string, v any) bool {
		out = append(out, k+" "+v.(string))
		return false
	})
	return out
}

// protectToken protects a denom's voucher token on Ethereum.
func (rt *Route) protectToken(remote string) {
	if remote != "" && !rt.protected.Has(strings.ToLower(remote)) {
		rt.protected.Set(strings.ToLower(remote), RoleVoucherToken)
	}
}

// Refused lists the refused send recipients.
func (rt *Route) Refused() []string {
	var out []string
	rt.refused.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// ------------------------------------------------------------------- denom

// Denom is one denom of a route: its configuration, its meters and queues,
// and its accounting.
type Denom struct {
	Name           string // the escrow denom (KindUnescrow) or the voucher's IBC denom (KindMint)
	Config         DenomConfig
	LaunchCapFloor int64 // the cap floor it was enabled with: lowering never goes below it

	meter       Meter
	queues      avl.Tree // recipient -> *queue
	waiting     avl.Tree // recipient -> true while its queue holds an open claim
	cursor      string   // the last recipient served
	refundMeter Meter
	refundQueue avl.Tree // seqKey(n) -> send key, oldest first
	refundSeq   int64

	Totals Totals
}

// Totals is a denom's accounting (ADR pr6375 §7.11's claim, refund and loss
// terms, kept on chain so monitors read them at a pinned height).
type Totals struct {
	Credited      int64 // booked as claims, by packets and votes
	Owed          int64 // open claims' remainders
	Withheld      int64 // withheld claims' remainders
	Swept         int64 // live sweep entries
	Paid          int64 // claim installments paid to recipients
	Fees          int64 // claim fee installments paid to the collector
	SweepPaid     int64 // sweep entries paid by decision
	Outstanding   int64 // KindMint: vouchers this route has in circulation
	Returning     int64 // KindMint: vouchers burned by sends not settled yet (in flight, or refund owed)
	InFlight      int64 // the amounts of the open send records: a bound of every refund owed (QueuedRefunds, Returning)
	Sent          int64 // escrowed (KindUnescrow) or burned (KindMint) by recorded sends
	SendFees      int64 // fees charged on sends
	Refunded      int64 // refunds paid
	QueuedRefunds int64 // refunds owed and not paid yet
	Lost          int64 // the loss ledger's total
	Recapitalized int64
	Reduced       int64
	Accepted      int64
}

// Unrecovered is the loss ledger's economic open total, the term of the
// supply identity (ADR pr6375 §7.11): losses neither recapitalized nor
// reduced. An accepted deficit restores neither backing nor liabilities, so
// it stays unrecovered.
func (t Totals) Unrecovered() int64 {
	u := t.Lost - t.Recapitalized - t.Reduced
	if u < 0 {
		return 0
	}
	return u
}

// Unresolved is what of the losses still waits for a restoring decision
// (ADR pr6375 §7.9): the unrecovered losses not accepted as a deficit
// either. A route reopens only when it is zero.
func (t Totals) Unresolved() int64 {
	u := t.Unrecovered() - t.Accepted
	if u < 0 {
		return 0
	}
	return u
}

// booked is what a minted denom counts against its supply cap (ADR pr6375
// §6.8): the vouchers in circulation, the vouchers burned by sends that may
// still be refunded (minted again), and every claim and sweep entry not paid
// yet.
func (t Totals) booked() int64 {
	return boundAdd(boundAdd(boundAdd(boundAdd(t.Outstanding, t.Returning), t.Owed), t.Withheld), t.Swept)
}

// queue is one recipient's open claims, oldest first, and its meter.
type queue struct {
	items avl.Tree // seqKey(seq) -> packet key
	meter Meter
	next  int64
}

// SetDenom enables a denom on the route or replaces its configuration. A new
// denom's meters start empty as of now in epoch. A new minted denom starts
// with outstanding, the vouchers of it already in circulation (minted before
// the route was controlled), counted against its supply cap from the start;
// outstanding is ignored otherwise. The cap floor never goes below the one the
// denom was enabled with, and a denom never changes accounting.
func (rt *Route) SetDenom(name string, c DenomConfig, now, epoch, outstanding int64) error {
	if name == "" {
		return errors.New("controls: empty denom")
	}
	if outstanding < 0 {
		return errors.New("controls: negative outstanding supply")
	}
	if err := c.Validate(); err != nil {
		return err
	}
	if d := rt.Denom(name); d != nil {
		if c.Kind != d.Config.Kind {
			return errors.New("controls: a denom never changes accounting")
		}
		if c.CapFloor < d.LaunchCapFloor {
			return ufmt.Errorf("controls: the cap floor (%d) cannot go below its launch value (%d)", c.CapFloor, d.LaunchCapFloor)
		}
		d.Config = c
		rt.protectToken(c.Remote)
		return nil
	}
	d := &Denom{Name: name, Config: c, LaunchCapFloor: c.CapFloor}
	if c.Kind == KindMint {
		d.Totals.Outstanding = outstanding
	}
	d.meter = NewMeter(now, epoch)
	d.refundMeter = NewMeter(now, 0)
	rt.denoms.Set(name, d)
	rt.protectToken(c.Remote)
	return nil
}

// Denom is the denom's state, or nil.
func (rt *Route) Denom(name string) *Denom {
	v := rt.denoms.Get(name)
	if v == nil {
		return nil
	}
	return v.(*Denom)
}

// Denoms lists the route's denoms.
func (rt *Route) Denoms() []string {
	var out []string
	rt.denoms.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// Unrecovered is the economic open loss total over the route's denoms,
// saturating at the int64 maximum.
func (rt *Route) Unrecovered() int64 {
	var u int64
	rt.denoms.Iterate("", "", func(_ string, v any) bool {
		u = boundAdd(u, v.(*Denom).Totals.Unrecovered())
		return false
	})
	return u
}

// Unresolved is the loss total over the route's denoms that still waits for
// a restoring decision, saturating at the int64 maximum.
func (rt *Route) Unresolved() int64 {
	var u int64
	rt.denoms.Iterate("", "", func(_ string, v any) bool {
		u = boundAdd(u, v.(*Denom).Totals.Unresolved())
		return false
	})
	return u
}

// DayCap is the denom's day cap: max(CapFloor, lock/10) for an unescrowed
// denom, CapFloor for a minted one.
func (d *Denom) DayCap(lock int64) int64 {
	if d.Config.Kind == KindMint {
		return d.Config.CapFloor
	}
	c := lock / 10
	if c < d.Config.CapFloor {
		c = d.Config.CapFloor
	}
	return c
}

// Reserved is the escrow the denom's claims and owed refunds hold: open and
// withheld claim remainders, and every queued (held or not) refund, so
// voids, credits and payouts never spend it twice (ADR pr6375 §7.9, §7.12:
// refund liabilities move with the backing).
func (d *Denom) Reserved() int64 {
	return boundAdd(boundAdd(d.Totals.Owed, d.Totals.Withheld), d.Totals.QueuedRefunds)
}

// liabilities is what the denom's claims and sweep entries owe, saturating.
func (t Totals) liabilities() int64 { return boundAdd(boundAdd(t.Owed, t.Withheld), t.Swept) }

// CheckSend is what a send of a gno-native token must satisfy (ADR pr6375
// §7.8): between the minimum and the maximum. A minted denom's sends are
// voucher returns and are never limited.
func (d *Denom) CheckSend(amount int64) error {
	if d.Config.Kind != KindUnescrow {
		return nil
	}
	if amount <= 0 {
		return errors.New("controls: the amount must be positive")
	}
	if amount < d.Config.SendMin {
		return ufmt.Errorf("controls: %d is below the minimum send of %d", amount, d.Config.SendMin)
	}
	if amount > d.Config.SendMax {
		return ufmt.Errorf("controls: %d is above the maximum send of %d", amount, d.Config.SendMax)
	}
	return nil
}

// ------------------------------------------------------------------ claims

// Claim is one credit the route owes a recipient, keyed by its packet.
type Claim struct {
	Key     string // the packet key (receiving client / sequence)
	Denom   string
	To      address
	Amount  int64 // what it owes in all, after any reduction
	Paid    int64 // fee included
	Reduced int64 // cut by liability reductions
	At      int64 // credited at, unix time
	Height  int64 // credited at, block height
	By      string
	State   string
	Seq     int64 // its place in the recipient's queue
}

// Remaining is what the claim still owes.
func (c *Claim) Remaining() int64 { return c.Amount - c.Paid }

// SweepEntry is a credit that pays nobody until a decision directs it (ADR
// pr6375 §7.1): an amount below the fee, above the free lock, or to a bridge
// realm.
type SweepEntry struct {
	Key     string
	Denom   string
	To      string // the receiver the packet named
	Amount  int64
	Reason  string
	Reduced int64 // cut by liability reductions
	Height  int64
	Voided  bool   // voided as forged
	Paid    bool   // paid by a sweep decision, or replaced by a credit by vote
	PaidTo  string // where a sweep decision paid it
}

// Payment is what a claim payout or a sweep payment moves: Amount to To and
// Fee to the route's fee collector, out of the denom's escrow (KindUnescrow)
// or as newly minted vouchers (KindMint).
type Payment struct {
	Key    string
	Denom  string
	To     address
	Amount int64
	Fee    int64
}

// Claim is the claim of a packet key, by value, and whether it exists.
func (rt *Route) Claim(key string) (Claim, bool) {
	c := rt.claim(key)
	if c == nil {
		return Claim{}, false
	}
	return *c, true
}

func (rt *Route) claim(key string) *Claim {
	v := rt.claims.Get(key)
	if v == nil {
		return nil
	}
	return v.(*Claim)
}

// Sweep is the sweep entry of a packet key, by value, and whether it exists.
func (rt *Route) Sweep(key string) (SweepEntry, bool) {
	e := rt.sweep(key)
	if e == nil {
		return SweepEntry{}, false
	}
	return *e, true
}

func (rt *Route) sweep(key string) *SweepEntry {
	v := rt.sweeps.Get(key)
	if v == nil {
		return nil
	}
	return v.(*SweepEntry)
}

// CheckCredit is the refusal test of a receive, run before any state change
// (ADR pr6375 §7.3): the denom must be enabled on the route, the amount
// positive and, for a minted denom, within its supply cap (§6.8). A refusal is
// answered with an error acknowledgement, so the sender is refunded at the
// source.
func (rt *Route) CheckCredit(denom string, amount int64) error {
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if amount <= 0 {
		return errors.New("controls: the amount must be positive")
	}
	if d.Config.Kind == KindMint {
		booked := d.Totals.booked()
		if amount > d.Config.SupplyCap-booked {
			return ufmt.Errorf("controls: %d would take %s past its supply cap of %d (%d outstanding or booked)", amount, denom, d.Config.SupplyCap, booked)
		}
	}
	return nil
}

// Credit books a received transfer under its packet key, in the same
// transaction as the packet's receipt: a claim in the recipient's queue, or an
// entry of the sweep queue. sweepReason, when not empty, sweeps it whatever
// the amount (a bridge realm receiver); otherwise an amount below the fee, or
// for an unescrowed denom above the free lock (lock minus what claims reserve),
// is swept. It returns whether it was swept. Run CheckCredit first.
func (rt *Route) Credit(now, height, epoch int64, key, denom string, to address, amount int64, by, sweepReason string, lock int64) (bool, error) {
	if err := rt.CheckCredit(denom, amount); err != nil {
		return false, err
	}
	if rt.claims.Has(key) || rt.sweeps.Has(key) {
		return false, errors.New("controls: packet " + key + " is credited already")
	}
	d := rt.Denom(denom)
	if _, ok := checkedAdd(d.Totals.liabilities(), amount); !ok {
		return false, errors.New("controls: the amount would overflow what is owed")
	}
	reason := sweepReason
	if reason == "" {
		switch {
		case amount < d.Config.Fee:
			reason = "below the fee"
		case d.Config.Kind == KindUnescrow && amount > lock-d.Reserved():
			reason = "above the free lock"
		}
	}
	if reason != "" {
		rt.sweeps.Set(key, &SweepEntry{Key: key, Denom: denom, To: string(to), Amount: amount, Reason: reason, Height: height})
		d.Totals.Swept = mustAdd(d.Totals.Swept, amount)
		return true, nil
	}
	if !to.IsValid() {
		return false, errors.New("controls: invalid recipient " + string(to))
	}
	rt.enqueue(d, now, height, epoch, key, to, amount, by)
	return false, nil
}

func (rt *Route) enqueue(d *Denom, now, height, epoch int64, key string, to address, amount int64, by string) *Claim {
	q := d.queue(to, now, epoch)
	q.next++
	c := &Claim{Key: key, Denom: d.Name, To: to, Amount: amount, At: now, Height: height, By: by, State: Open, Seq: q.next}
	rt.claims.Set(key, c)
	q.items.Set(seqKey(c.Seq), key)
	d.waiting.Set(string(to), true)
	d.Totals.Owed = mustAdd(d.Totals.Owed, amount)
	d.Totals.Credited = statAdd(d.Totals.Credited, amount)
	return c
}

// queue is a recipient's queue, made on first use with its meter empty as of
// now in epoch: a queue made after an epoch's reset starts empty at its first
// credit, as every meter does.
func (d *Denom) queue(to address, now, epoch int64) *queue {
	if v := d.queues.Get(string(to)); v != nil {
		return v.(*queue)
	}
	q := &queue{meter: NewMeter(now, epoch)}
	d.queues.Set(string(to), q)
	return q
}

// oldestOpen is the first open claim of a queue, or nil.
func (rt *Route) oldestOpen(q *queue) *Claim {
	var found *Claim
	q.items.Iterate("", "", func(_ string, v any) bool {
		c := rt.claim(v.(string))
		if c != nil && c.State == Open {
			found = c
			return true
		}
		return false
	})
	return found
}

// nextRecipient is the waiting recipient after the cursor, wrapping.
func (d *Denom) nextRecipient() string {
	next := ""
	d.waiting.Iterate(d.cursor+"\x00", "", func(k string, _ any) bool {
		next = k
		return true
	})
	if next == "" {
		d.waiting.Iterate("", "", func(k string, _ any) bool {
			next = k
			return true
		})
	}
	return next
}

// MeterLevels refills and reads the bridge meter and a recipient's meter of
// a denom under the payouts epoch (a recipient without a queue reads 0).
func (rt *Route) MeterLevels(now, epoch, epochAt int64, denom string, to address, lock int64) (bridge, recipient int64) {
	d := rt.Denom(denom)
	if d == nil {
		return 0, 0
	}
	c := d.DayCap(lock)
	d.meter.Refill(now, c, c, epoch, epochAt)
	if v := d.queues.Get(string(to)); v != nil {
		q := v.(*queue)
		q.meter.Refill(now, c/4, c/4, epoch, epochAt)
		recipient = q.meter.Level
	}
	return d.meter.Level, recipient
}

// PayClaims pays up to n claims of a denom (n ≤ MaxClaims), taking recipients
// round-robin and each recipient's oldest open claim (ADR pr6375 §7.1):
//
//   - a turn pays at most min(bridge meter, recipient meter), and for an
//     unescrowed denom never more than the lock still holds;
//   - a claim's first installment is the fee, whole, to the fee collector;
//   - a later installment is paid only when both meters hold at least
//     min(what the claim still owes, the fee): no slivers;
//   - a recipient whose meters hold less is passed over, its meter refilling
//     for a later turn.
//
// The bridge meter refills at the day cap a day, the recipient's at a quarter
// of it; both empty when the payouts epoch changes. It books every payment
// and returns them for the caller to make; at most n claims are paid and at
// most 4n recipients looked at.
func (rt *Route) PayClaims(now, epoch, epochAt int64, denom string, n int, lock int64) ([]Payment, error) {
	d := rt.Denom(denom)
	if d == nil {
		return nil, errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if n < 1 {
		return nil, errors.New("controls: n must be positive")
	}
	if n > MaxClaims {
		n = MaxClaims
	}
	var out []Payment
	for visits := 0; len(out) < n && visits < 4*n && d.waiting.Size() > 0; visits++ {
		addr := d.nextRecipient()
		d.cursor = addr
		q := d.queues.Get(addr).(*queue)
		c := rt.oldestOpen(q)
		if c == nil {
			d.waiting.Remove(addr)
			continue
		}
		dayCap := d.DayCap(lock)
		d.meter.Refill(now, dayCap, dayCap, epoch, epochAt)
		q.meter.Refill(now, dayCap/4, dayCap/4, epoch, epochAt)
		avail := d.meter.Level
		if q.meter.Level < avail {
			avail = q.meter.Level
		}
		// A claim payout never takes the escrow owed refunds reserve.
		if d.Config.Kind == KindUnescrow && avail > lock-d.Totals.QueuedRefunds {
			avail = lock - d.Totals.QueuedRefunds
		}
		rem := c.Remaining()
		fee := int64(0)
		if c.Paid == 0 {
			fee = d.Config.Fee
			if fee > rem {
				fee = rem
			}
			if avail <= 0 || avail < fee {
				continue // dry: the fee is the first installment, whole
			}
		} else {
			need := d.Config.Fee
			if need > rem {
				need = rem
			}
			if avail <= 0 || avail < need {
				continue // no slivers
			}
		}
		pay := rem - fee
		if pay > avail-fee {
			pay = avail - fee
		}
		if c.Paid == 0 && pay > 0 {
			// No sliver after the fee either: the rest of a first installment
			// is paid only if it is at least min(what remains, the fee).
			need := d.Config.Fee
			if need > rem-fee {
				need = rem - fee
			}
			if pay < need {
				pay = 0
			}
		}
		total := fee + pay
		c.Paid += total // at most the claim's amount
		d.meter.Take(total)
		q.meter.Take(total)
		d.Totals.Owed -= total
		d.Totals.Paid = statAdd(d.Totals.Paid, pay)
		d.Totals.Fees = statAdd(d.Totals.Fees, fee)
		if d.Config.Kind == KindMint {
			d.Totals.Outstanding = mustAdd(d.Totals.Outstanding, total)
		} else {
			lock -= total
		}
		if c.Remaining() == 0 {
			c.State = Done
			rt.dequeue(d, c, q)
		}
		out = append(out, Payment{Key: c.Key, Denom: denom, To: c.To, Amount: pay, Fee: fee})
	}
	return out, nil
}

// dequeue takes a claim out of its queue; a queue left with no open claim
// leaves the ring.
func (rt *Route) dequeue(d *Denom, c *Claim, q *queue) {
	q.items.Remove(seqKey(c.Seq))
	if q.items.Size() == 0 {
		d.waiting.Remove(string(c.To))
	}
}

// Waiting is how many recipients of a denom have an open claim.
func (rt *Route) Waiting(denom string) int {
	d := rt.Denom(denom)
	if d == nil {
		return 0
	}
	return d.waiting.Size()
}

// Send records and refunds are in refunds.gno; voids, credits by vote,
// sweeps and the loss ledger in voids.gno.

func parseKeys(keys []string) error {
	if len(keys) == 0 {
		return errors.New("controls: no packet key")
	}
	if len(keys) > MaxKeys {
		return ufmt.Errorf("controls: more than %d packet keys", MaxKeys)
	}
	seen := map[string]bool{}
	for _, k := range keys {
		if _, _, ok := ParsePacketKey(k); !ok {
			return errors.New("controls: not a packet key: " + k)
		}
		if seen[k] {
			return errors.New("controls: packet key named twice: " + k)
		}
		seen[k] = true
	}
	return nil
}
