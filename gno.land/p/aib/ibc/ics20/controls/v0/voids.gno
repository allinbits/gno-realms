package controls

import (
	"errors"

	"gno.land/p/nt/ufmt/v0"
)

// CauseRefundForDelivered is the cause of a settlement's loss: a refund paid
// for a packet the destination delivered.
const CauseRefundForDelivered = "refund-for-delivered"

// Loss chains: where a recognized loss happened (ADR pr6375 §7.9).
const (
	ChainGno      = "gno"
	ChainEthereum = "ethereum"
)

// Loss is one entry of the loss ledger: a loss recognized by a decided void
// or a reconciliation outcome, keyed by its packet (ADR pr6375 §7.9).
// Monitors and guardians cannot record one.
type Loss struct {
	Key       string // packet key
	Direction string // DirRecv or DirSend: which of the client's packet spaces Key is in
	Denom     string
	Amount    uint256
	Chain     string
	Incident  string
	Cause     string // "forged payout", or the reconciliation outcome's words
}

// Recap is a recapitalization a decision authorized: Amount of Denom to be
// paid into the escrow through the transfer app's Recapitalize, credited to
// the accounted backing and debited from the unrecovered losses.
type Recap struct {
	ID       int64
	Denom    string
	Amount   uint256
	Incident string
	Paid     bool
	PaidBy   address
	Revoked  bool // revoked by decision, or by an alternative resolution of its loss
}

// Packet directions of a loss: a packet received on gno.land (its claim or
// sweep entry), or one gno.land sent (its send record). A client's inbound
// and outbound sequences are distinct spaces, so the direction is part of a
// packet's identity.
const (
	DirRecv = "recv"
	DirSend = "send"
)

// lossID is a packet's economic-loss identity, and the key of its entry in
// the ledger: one loss per packet and direction, whatever its cause (kept as
// the entry's metadata), so no payout is booked twice through two paths (a
// void, a settlement, a recorded loss), and the two directions of one client
// and sequence are two entries.
func lossID(dir, key string) string { return dir + "|" + key }

// LossBooked reports whether a loss of the packet key in direction dir is in
// the ledger.
func (rt *Route) LossBooked(dir, key string) bool { return rt.losses.Has(lossID(dir, key)) }

// IncidentTotals is the loss ledger of one incident on one denom: what it
// lost and how much of that each restoring decision resolved. Resolutions of
// an incident never exceed its losses, and an authorized recapitalization not
// yet paid holds its part (ADR pr6375 §7.9).
type IncidentTotals struct {
	// Lifetime statistics, saturating, never read by a check.
	Lost          uint256
	Recapitalized uint256
	Reduced       uint256
	Accepted      uint256
	// The outstanding balances (see Totals).
	OpenUnrecovered uint256
	OpenUnresolved  uint256
	// Mirror marks an incident whose losses were paid out on Ethereum
	// (RecordLoss with chain "ethereum"): Ethereum's ledger is the
	// authoritative one (the payout chain books a loss), and the record here
	// is a mirror, resolved only by an accepted deficit, never reduced or
	// recapitalized. An incident holds mirrors or authoritative losses, never
	// both (Booked: it holds a loss, so its kind is fixed).
	Mirror bool
	Booked bool
}

// checkIncidentKind is why a loss, a mirror or not, cannot be booked under
// incident on denom, or nil: an incident holds one kind only.
func (rt *Route) checkIncidentKind(denom, incident string, mirror bool) error {
	it := rt.Incident(denom, incident)
	if it.Booked && it.Mirror != mirror {
		if it.Mirror {
			return errors.New("controls: incident " + incident + " holds mirrors of losses paid on Ethereum: book a loss paid here under another incident")
		}
		return errors.New("controls: incident " + incident + " holds losses paid here: book a mirror of a loss paid on Ethereum under another incident")
	}
	return nil
}

// checkRemedy is why a reduction or a recapitalization cannot act on
// incident's losses on denom, or nil: a mirror is resolved only by an
// accepted deficit, the payout chain's ledger carrying the remedies.
func (rt *Route) checkRemedy(denom, incident string) error {
	if rt.Incident(denom, incident).Mirror {
		return errors.New("controls: incident " + incident + " mirrors losses paid on Ethereum, whose ledger remedies them: resolve the mirror by an accepted deficit only")
	}
	return nil
}

func incidentKey(denom, incident string) string { return denom + "|" + incident }

func (rt *Route) incident(denom, incident string) *IncidentTotals {
	k := incidentKey(denom, incident)
	if v := rt.incidents.Get(k); v != nil {
		return v.(*IncidentTotals)
	}
	it := &IncidentTotals{}
	rt.incidents.Set(k, it)
	return it
}

// Incident is the loss ledger of an incident on a denom, by value.
func (rt *Route) Incident(denom, incident string) IncidentTotals {
	if v := rt.incidents.Get(incidentKey(denom, incident)); v != nil {
		return *v.(*IncidentTotals)
	}
	return IncidentTotals{}
}

// recapitalizable is what of an incident's losses on denom a
// recapitalization may still restore: its unrecovered losses (accepted
// deficits included: accepting a deficit restores no backing, so a later
// recapitalization may), minus the recapitalizations authorized and not
// paid (except skip, an authorization being paid).
func (rt *Route) recapitalizable(denom, incident string, skip int64) uint256 {
	return sub0(rt.Incident(denom, incident).OpenUnrecovered, rt.openRecaps(denom, incident, skip))
}

// Voidable reports whether a void as forged (or as withheld) can take the
// claim or sweep entry of key as it stands: an open claim either way, a
// withheld or paid claim as forged only, a sweep entry as forged only: a live
// one, or one a sweep decision paid (its payout becomes the loss), not one a
// credit by vote replaced (its claim carries the payout).
func (rt *Route) Voidable(key string, forged bool) bool {
	if rt.LossBooked(DirRecv, key) {
		return false // its loss is booked (a forged-receive settlement or a recorded loss)
	}
	if c := rt.claim(key); c != nil {
		switch c.State {
		case Open:
			return true
		case Withheld, Done:
			return forged
		}
		return false
	}
	if e := rt.sweep(key); e != nil {
		return forged && !e.Voided && (!e.Paid || e.PaidTo != PaidByVote)
	}
	return false
}

// PaidByVote is a sweep entry's PaidTo when a credit by vote replaced it.
const PaidByVote = "credit by vote"

// Void voids the claims and sweep entries of keys (ADR pr6375 §7.9). A
// withheld void keeps a claim's remainder booked and restorable; a forged void
// drops it and books what was already paid as a loss. A void never creates a
// refund at the source: the packet was acknowledged as a success. All keys are
// checked before anything changes.
func (rt *Route) Void(keys []string, forged bool, incident string) error {
	if err := parseKeys(keys); err != nil {
		return err
	}
	for _, k := range keys {
		if !rt.Voidable(k, forged) {
			return errors.New("controls: " + k + " cannot be voided " + voidWord(forged) + " as it stands")
		}
		// A forged void books a loss paid here: never under a mirror
		// incident. A withheld one books none, so any incident takes it.
		if !forged {
			continue
		}
		denom := ""
		if c := rt.claim(k); c != nil {
			denom = c.Denom
		} else if e := rt.sweep(k); e != nil {
			denom = e.Denom
		}
		if err := rt.checkIncidentKind(denom, incident, false); err != nil {
			return err
		}
	}
	for _, k := range keys {
		if c := rt.claim(k); c != nil {
			rt.voidClaim(c, forged, incident)
			continue
		}
		e := rt.sweep(k)
		e.Voided = true
		d := rt.Denom(e.Denom)
		if !e.Paid {
			d.Totals.Swept = mustSub(d.Totals.Swept, e.Amount)
		}
		// A paid entry's payout left the swept total when it was paid: what
		// the sweep decision paid, and what a claim moved here had paid, is
		// the loss, booked once.
		if paid := e.paidOut(); paid > 0 {
			rt.addLoss(d, Loss{Key: k, Direction: DirRecv, Denom: e.Denom, Amount: paid, Chain: ChainGno, Incident: incident, Cause: "forged payout"})
		}
	}
	return nil
}

func voidWord(forged bool) string {
	if forged {
		return "as forged"
	}
	return "as withheld"
}

func (rt *Route) voidClaim(c *Claim, forged bool, incident string) {
	d := rt.Denom(c.Denom)
	rem := c.Remaining()
	switch c.State {
	case Open:
		d.Totals.Owed = mustSub(d.Totals.Owed, rem)
		rt.dequeue(d, c, d.queues.Get(string(c.To)).(*queue))
		if forged {
			c.State = Forged
		} else {
			d.Totals.Withheld = mustAdd(d.Totals.Withheld, rem)
			c.State = Withheld
		}
	case Withheld:
		d.Totals.Withheld = mustSub(d.Totals.Withheld, rem)
		c.State = Forged
	case Done:
		c.State = Forged
	}
	if forged && c.Paid > 0 {
		rt.addLoss(d, Loss{Key: c.Key, Direction: DirRecv, Denom: c.Denom, Amount: c.Paid, Chain: ChainGno, Incident: incident, Cause: "forged payout"})
	}
}

// The loss ledger's remedies follow one rule (ADR 0004, R13). A remedy that
// restores backing or lowers liabilities (a paid recapitalization, a
// reduction) is bounded by the incident's unrecovered losses and lowers the
// unresolved ones only as far as they remain: it may repair an accepted
// deficit. An accepted deficit (Accept, or a reopening) is bounded by the
// unresolved losses and lowers only them: the loss stays unrecovered.

// accept records amount, which its caller checked is within the incident's
// unresolved losses, as an accepted deficit: off the unresolved balances of
// the denom and the incident only.
func (rt *Route) accept(denom, incident string, amount uint256) {
	d := rt.Denom(denom)
	t := &d.Totals
	it := rt.incident(denom, incident)
	if amount > it.OpenUnresolved || amount > t.OpenUnresolved {
		panic("controls: an acceptance beyond the unresolved losses")
	}
	defer rt.noteUnresolved(d, t.OpenUnresolved)
	t.OpenUnresolved -= amount
	it.OpenUnresolved -= amount
	t.Accepted, it.Accepted = statAdd(t.Accepted, amount), statAdd(it.Accepted, amount)
}

// acceptAll records the whole of an incident's unresolved losses on denom as
// an accepted deficit (a reopening's batch).
func (rt *Route) acceptAll(denom, incident string) {
	d := rt.Denom(denom)
	t := &d.Totals
	it := rt.incident(denom, incident)
	defer rt.noteUnresolved(d, t.OpenUnresolved)
	stat := it.OpenUnresolved
	t.OpenUnresolved = mustSub(t.OpenUnresolved, stat) // the incident's part is within the denom's
	it.OpenUnresolved = 0
	t.Accepted, it.Accepted = statAdd(t.Accepted, stat), statAdd(it.Accepted, stat)
}

// recover takes a paid recapitalization or a reduction off the outstanding
// balances: off the unrecovered losses, and off the unresolved ones as far
// as they go (an accepted deficit it repairs is resolved already). Its
// caller checked amount is within the incident's unrecovered losses.
func (rt *Route) recover(denom, incident string, amount uint256) {
	d := rt.Denom(denom)
	t := &d.Totals
	it := rt.incident(denom, incident)
	if amount > it.OpenUnrecovered || amount > t.OpenUnrecovered {
		panic("controls: a recovery beyond the unrecovered losses")
	}
	defer rt.noteUnresolved(d, t.OpenUnresolved)
	x := amount
	if x > it.OpenUnresolved {
		x = it.OpenUnresolved
	}
	t.OpenUnrecovered -= amount
	it.OpenUnrecovered -= amount
	t.OpenUnresolved = mustSub(t.OpenUnresolved, x) // the incident's unresolved part is within the denom's
	it.OpenUnresolved -= x
}

// lossFits refuses a loss the ledger's outstanding balances (the denom's and
// the incident's unrecovered and unresolved losses) could not hold without
// passing 2^256 - 1. Lifetime statistics are not checked: they saturate, and
// a resolved loss frees its capacity.
func (rt *Route) lossFits(denom, incident string, amount uint256) error {
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: a loss of " + denom + " is a positive amount of an enabled denom")
	}
	it := rt.Incident(denom, incident)
	for _, b := range []uint256{d.Totals.OpenUnrecovered, d.Totals.OpenUnresolved, it.OpenUnrecovered, it.OpenUnresolved} {
		if _, ok := checkedAdd(b, amount); !ok {
			return errors.New("controls: the loss would overflow the ledger's balances")
		}
	}
	return nil
}

// addLoss books a loss its caller checked fits (lossFits, or an amount
// within a booked claim or refund); an addition that would still overflow
// is a broken invariant and aborts.
func (rt *Route) addLoss(d *Denom, l Loss) {
	it := rt.incident(l.Denom, l.Incident)
	if l.Direction != DirRecv && l.Direction != DirSend || rt.losses.Has(lossID(l.Direction, l.Key)) {
		panic("controls: a packet's loss is booked once")
	}
	rt.losses.Set(lossID(l.Direction, l.Key), &l)
	if !it.Booked {
		it.Booked, it.Mirror = true, l.Chain == ChainEthereum
	}
	was := d.Totals.OpenUnresolved
	d.Totals.OpenUnrecovered = mustAdd(d.Totals.OpenUnrecovered, l.Amount)
	it.OpenUnrecovered = mustAdd(it.OpenUnrecovered, l.Amount)
	d.Totals.OpenUnresolved = mustAdd(d.Totals.OpenUnresolved, l.Amount)
	it.OpenUnresolved = mustAdd(it.OpenUnresolved, l.Amount)
	rt.noteUnresolved(d, was)
	d.Totals.Lost, it.Lost = statAdd(d.Totals.Lost, l.Amount), statAdd(it.Lost, l.Amount)
	rt.lossesBooked++
}

// Restore restores withheld claims (ADR pr6375 §7.9: a withheld void can be
// restored): each goes back into its recipient's queue at its place, opening
// one for it if it has none (as of now in epoch). A withheld claim's
// remainder stayed booked (reserved escrow, or counted against the supply
// cap), so restoring it books nothing new. A forged void and a voided sweep
// entry are final: their remainders were released, and other credits may
// hold that escrow or supply since.
func (rt *Route) Restore(keys []string, now, epoch int64) error {
	if err := parseKeys(keys); err != nil {
		return err
	}
	for _, k := range keys {
		if c := rt.claim(k); c == nil || c.State != Withheld {
			return errors.New("controls: " + k + " is no withheld claim (only a withheld void is restored)")
		}
	}
	for _, k := range keys {
		rt.restoreClaim(rt.claim(k), now, epoch)
	}
	return nil
}

func (rt *Route) restoreClaim(c *Claim, now, epoch int64) {
	d := rt.Denom(c.Denom)
	rem := c.Remaining()
	d.Totals.Withheld = mustSub(d.Totals.Withheld, rem)
	if rem == 0 {
		c.State = Done
		return
	}
	c.State = Open
	d.Totals.Owed = mustAdd(d.Totals.Owed, rem)
	q := d.queue(c.To, now, epoch)
	q.items.Set(seqKey(c.Seq), c.Key)
	d.waiting.Set(string(c.To), true)
}

// CreditByVote credits a packet by decision, the manual fallback for a
// griefed transfer (ADR pr6375 §7.9). The caller checked that the packet's
// acknowledgement on this chain is a success: an error-acknowledged packet is
// refunded at its source and never credited. Credits are deduplicated
// against every claim and payment of the packet: only a receive these
// controls booked, a live sweep entry recorded at its receipt after the
// route's activation, is credited, which replaces the entry. A receive from
// before the activation was paid at once by impl/v0 and is never credited
// again. The amount is the sweep entry's whole amount (any haircut goes
// through Reduce), at least the fee, and for an unescrowed denom never above
// the free lock.
func (rt *Route) CreditByVote(now, height, epoch int64, key, denom string, to address, amount, lock uint256) error {
	if err := rt.checkPrepared(); err != nil {
		return err
	}
	if _, _, ok := ParsePacketKey(key); !ok {
		return errors.New("controls: not a packet key: " + key)
	}
	if rt.claims.Has(key) {
		return errors.New("controls: packet " + key + " has a claim already")
	}
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if !to.IsValid() {
		return errors.New("controls: invalid recipient " + string(to))
	}
	e := rt.sweep(key)
	if e == nil || e.Height < rt.Activated {
		return errors.New("controls: packet " + key + " was not received under the route's controls (no sweep entry booked at its receipt): a receive from before the activation was paid already")
	}
	if e.Voided || e.Paid || e.Denom != denom {
		return errors.New("controls: packet " + key + "'s sweep entry is voided, paid or of another denom")
	}
	if e.FromClaim {
		return errors.New("controls: packet " + key + " was credited as a claim already, moved to the sweep queue: a sweep decision pays it")
	}
	// The full payable amount: a credit never drops part of an entitlement
	// (a haircut goes through Reduce, against an incident).
	if amount != e.Amount || amount < d.Config.Fee {
		return ufmt.Errorf("controls: a credit by vote is the sweep entry's whole amount (%s), at least the fee (%s), not %s", u(e.Amount), u(d.Config.Fee), u(amount))
	}
	if free := sub0(lock, d.Reserved()); d.Config.Kind == KindUnescrow && amount > free {
		return ufmt.Errorf("controls: %s is above the free lock of %s", u(amount), u(free))
	}
	// A minted credit replaces its sweep entry within the supply already
	// booked for it: amount never exceeds the entry.
	e.Paid = true
	e.PaidTo = PaidByVote
	d.Totals.Swept = mustSub(d.Totals.Swept, e.Amount)
	rt.enqueue(d, now, height, epoch, key, to, amount, ByVote)
	return nil
}

// CreditPending credits by decision a packet received on the route whose
// asynchronous acknowledgement is still unwritten (ADR pr6375 §7.9): the
// caller checked that the core received it after the route's activation and
// writes its success acknowledgement in the same transaction, so the packet
// can never be refunded at its source. Nothing was booked at its receipt, so
// it has no claim or sweep entry; carried is what the packet carried, which
// the amount must be (a haircut goes through Reduce), at least the fee; for
// an unescrowed denom it is never above the free lock, for a minted one never
// past the supply cap.
func (rt *Route) CreditPending(now, height, epoch int64, key, denom string, to address, amount, carried, lock uint256) error {
	if _, _, ok := ParsePacketKey(key); !ok {
		return errors.New("controls: not a packet key: " + key)
	}
	if rt.claims.Has(key) || rt.sweeps.Has(key) {
		return errors.New("controls: packet " + key + " is credited already")
	}
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if !to.IsValid() {
		return errors.New("controls: invalid recipient " + string(to))
	}
	// The full payable amount: the success acknowledgement written with it
	// ends the packet's entitlement at the source.
	if amount != carried || amount < d.Config.Fee {
		return ufmt.Errorf("controls: a credit by vote is what the packet carried (%s), at least the fee (%s), not %s", u(carried), u(d.Config.Fee), u(amount))
	}
	if free := sub0(lock, d.Reserved()); d.Config.Kind == KindUnescrow && amount > free {
		return ufmt.Errorf("controls: %s is above the free lock of %s", u(amount), u(free))
	}
	if _, ok := checkedAdd(d.Totals.liabilities(), amount); !ok {
		return errors.New("controls: the amount would overflow what is owed")
	}
	if d.Config.Kind == KindMint && amount > sub0(d.Config.SupplyCap, d.Totals.booked()) {
		return ufmt.Errorf("controls: %s would take %s past its supply cap", u(amount), denom)
	}
	rt.enqueue(d, now, height, epoch, key, to, amount, ByVote)
	return nil
}

// PaySweeps pays live sweep entries of one denom to an address by decision
// (ADR pr6375 §7.1: owed, paid only by a 7-day decision). For an unescrowed
// denom the total never exceeds the free lock (what open claims do not
// reserve). It books them and returns the
// payments.
func (rt *Route) PaySweeps(keys []string, to address, lock uint256) ([]Payment, error) {
	if err := rt.checkPrepared(); err != nil {
		return nil, err
	}
	if err := parseKeys(keys); err != nil {
		return nil, err
	}
	if !to.IsValid() {
		return nil, errors.New("controls: invalid recipient " + string(to))
	}
	denom := ""
	var total uint256
	for _, k := range keys {
		e := rt.sweep(k)
		if e == nil || e.Voided || e.Paid {
			return nil, errors.New("controls: " + k + " is no live sweep entry")
		}
		if denom == "" {
			denom = e.Denom
		} else if e.Denom != denom {
			return nil, errors.New("controls: a sweep payment names entries of one denom")
		}
		var ok bool
		// A payment past 2^256 - 1 could never be made at once: refused, a
		// smaller decision pays.
		if total, ok = checkedAdd(total, e.Amount); !ok {
			return nil, errors.New("controls: the sweep payment's total would overflow")
		}
	}
	d := rt.Denom(denom)
	if free := sub0(lock, d.Reserved()); d.Config.Kind == KindUnescrow && total > free {
		return nil, ufmt.Errorf("controls: %s is above the free lock of %s", u(total), u(free))
	}
	// A minted payment adds to the outstanding supply: refused whole, the
	// entries kept, when it would overflow it.
	if _, ok := checkedAdd(d.Totals.Outstanding, total); d.Config.Kind == KindMint && !ok {
		return nil, ufmt.Errorf("controls: %s of %s would overflow its outstanding supply", u(total), denom)
	}
	var out []Payment
	for _, k := range keys {
		e := rt.sweep(k)
		e.Paid, e.PaidTo = true, string(to)
		d.Totals.Swept = mustSub(d.Totals.Swept, e.Amount)
		d.Totals.SweepPaid = statAdd(d.Totals.SweepPaid, e.Amount)
		if d.Config.Kind == KindMint {
			d.Totals.Outstanding = mustAdd(d.Totals.Outstanding, e.Amount)
		}
		out = append(out, Payment{Key: k, Denom: denom, To: to, Amount: e.Amount})
	}
	return out, nil
}

// RecordLoss records a loss a reconciliation recognized (ADR pr6375 §7.12):
// a refund paid for a delivered packet, a forged delivery, a collision. cause
// says which, in words; one entry per packet and cause.
func (rt *Route) RecordLoss(key, denom string, amount uint256, chain, incident, cause string) error {
	if _, _, ok := ParsePacketKey(key); !ok {
		return errors.New("controls: not a packet key: " + key)
	}
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if amount == 0 {
		return errors.New("controls: a loss is positive")
	}
	if chain != ChainGno && chain != ChainEthereum {
		return errors.New("controls: a loss happens on gno or ethereum")
	}
	if incident == "" || cause == "" || cause == "forged payout" {
		return errors.New("controls: a loss names its incident and a reconciliation cause")
	}
	// A refund paid for a delivered packet, and a forged receive, are booked
	// by the settlement of their record (kind 12 actions 4 and 5), which
	// also settles it: recording one on its own would leave the record
	// unsettled and block the reopening.
	if cause == CauseRefundForDelivered || cause == CauseForgedReceive {
		return errors.New("controls: a " + cause + " loss is booked by settling its record")
	}
	// A loss on gno.land is of a packet gno.land received; one on Ethereum,
	// of a sequence gno.land sent (a collision with an honest send, or a
	// delivery of a sequence it never sent).
	dir := DirSend
	if chain == ChainGno {
		dir = DirRecv
		// A receive represented here (a claim or a sweep entry) books its
		// loss by its own operation: a void as forged, or a forged-receive
		// settlement, which also settle the claim or entry.
		if rt.claim(key) != nil || rt.sweep(key) != nil {
			return errors.New("controls: receive " + key + " is represented here: void it as forged or settle it (action 5)")
		}
	}
	if rt.LossBooked(dir, key) {
		return errors.New("controls: a loss of packet " + key + " is recorded already")
	}
	if err := rt.lossFits(denom, incident, amount); err != nil {
		return err
	}
	if err := rt.checkIncidentKind(denom, incident, chain == ChainEthereum); err != nil {
		return err
	}
	rt.addLoss(d, Loss{Key: key, Direction: dir, Denom: denom, Amount: amount, Chain: chain, Incident: incident, Cause: cause})
	return nil
}

// AuthorizeRecap records a recapitalization a decision authorized (ADR
// pr6375 §7.9): amount, at most what of the incident's losses on the denom no
// decision resolved or reserved yet, to be paid into the escrow. It returns
// the authorization's id.
func (rt *Route) AuthorizeRecap(denom string, amount uint256, incident string) (int64, error) {
	d := rt.Denom(denom)
	if d == nil {
		return 0, errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if d.Config.Kind != KindUnescrow {
		return 0, errors.New("controls: only an escrowed denom is recapitalized on gno.land")
	}
	if incident == "" {
		return 0, errors.New("controls: a recapitalization names its incident")
	}
	if err := rt.checkRemedy(denom, incident); err != nil {
		return 0, err
	}
	if amount == 0 || amount > rt.recapitalizable(denom, incident, 0) {
		return 0, ufmt.Errorf("controls: %s is not within incident %s's unrecovered losses not yet authorized", u(amount), incident)
	}
	p := openRecapPrefix(denom, incident)
	open := 0
	rt.openRecapIdx.Iterate(p, p+"~", func(string, any) bool {
		open++
		return open == MaxOpenRecaps
	})
	if open >= MaxOpenRecaps {
		return 0, ufmt.Errorf("controls: incident %s holds %d unpaid authorizations on %s already: pay or revoke one first", incident, MaxOpenRecaps, denom)
	}
	rt.nRecaps++
	r := &Recap{ID: rt.nRecaps, Denom: denom, Amount: amount, Incident: incident}
	rt.recaps.Set(seqKey(rt.nRecaps), r)
	rt.openRecapIdx.Set(openRecapKey(r), r)
	return rt.nRecaps, nil
}

// openRecaps is what the unpaid recapitalizations of an incident on denom
// hold, the authorization skip aside: a walk of that incident's open
// authorizations only (at most MaxOpenRecaps).
func (rt *Route) openRecaps(denom, incident string, skip int64) uint256 {
	var n uint256
	p := openRecapPrefix(denom, incident)
	rt.openRecapIdx.Iterate(p, p+"~", func(_ string, v any) bool {
		if r := v.(*Recap); r.ID != skip {
			n = mustAdd(n, r.Amount) // each within the incident's losses
		}
		return false
	})
	return n
}

func openRecapPrefix(denom, incident string) string { return incidentKey(denom, incident) + "|" }

func openRecapKey(r *Recap) string { return openRecapPrefix(r.Denom, r.Incident) + seqKey(r.ID) }

// closeRecap takes an authorization out of the open index, as it is paid or
// revoked.
func (rt *Route) closeRecap(r *Recap) { rt.openRecapIdx.Remove(openRecapKey(r)) }

// unresolvedOf is what of an incident's losses on denom no decision resolved
// (recapitalized, reduced or accepted), unpaid authorizations aside: what an
// acceptance may take.
func (rt *Route) unresolvedOf(denom, incident string) uint256 {
	return rt.Incident(denom, incident).OpenUnresolved
}

// unrecoveredOf is what of an incident's losses on denom is not recovered
// (recapitalized or reduced), accepted deficits included: what a reduction
// may take.
func (rt *Route) unrecoveredOf(denom, incident string) uint256 {
	return rt.Incident(denom, incident).OpenUnrecovered
}

// revokeConflicting revokes the newest unpaid recapitalization authorizations
// of an incident until a reduction of amount leaves them within what the
// incident still has unrecovered: a reduction decided later supersedes them
// (ADR pr6375 §7.9). An accepted deficit supersedes none: a recapitalization
// may still restore it. The caller checked amount fits unrecoveredOf. One
// pass over the incident's open authorizations (at most MaxOpenRecaps): their
// total once, then the newest revoked first while it exceeds what remains.
func (rt *Route) revokeConflicting(denom, incident string, amount uint256) {
	var open []*Recap
	var total uint256
	p := openRecapPrefix(denom, incident)
	rt.openRecapIdx.Iterate(p, p+"~", func(_ string, v any) bool {
		r := v.(*Recap)
		open = append(open, r)
		total = mustAdd(total, r.Amount)
		return false
	})
	// What remains after the reduction (the caller checked amount fits).
	room := mustSub(rt.Incident(denom, incident).OpenUnrecovered, amount)
	for i := len(open) - 1; i >= 0 && room < total; i-- {
		total -= open[i].Amount
		rt.closeRecap(open[i])
		open[i].Revoked = true
	}
}

// RevokeRecap revokes an unpaid recapitalization authorization by decision,
// one whose funding fell through: its part of the incident's losses is free
// for another restoring decision.
func (rt *Route) RevokeRecap(id int64) error {
	v := rt.recaps.Get(seqKey(id))
	if v == nil {
		return ufmt.Errorf("controls: no recapitalization %d", id)
	}
	r := v.(*Recap)
	if r.Paid || r.Revoked {
		return ufmt.Errorf("controls: recapitalization %d is paid or revoked already", id)
	}
	rt.closeRecap(r)
	r.Revoked = true
	return nil
}

// Recap is a recapitalization authorization by id, by value.
func (rt *Route) Recap(id int64) (Recap, bool) {
	v := rt.recaps.Get(seqKey(id))
	if v == nil {
		return Recap{}, false
	}
	return *v.(*Recap), true
}

// Recapitalize books an authorized recapitalization as paid: the caller moved
// exactly its amount into the escrow, which now backs it, and the loss
// ledger's unrecovered total falls by it.
func (rt *Route) Recapitalize(id int64, denom string, amount uint256, by address) error {
	v := rt.recaps.Get(seqKey(id))
	if v == nil {
		return ufmt.Errorf("controls: no recapitalization %d", id)
	}
	r := v.(*Recap)
	if r.Paid || r.Revoked {
		return ufmt.Errorf("controls: recapitalization %d is paid or revoked", id)
	}
	if r.Denom != denom || r.Amount != amount {
		return ufmt.Errorf("controls: recapitalization %d is %s %s", id, u(r.Amount), r.Denom)
	}
	// Re-checked at payment: the incident's losses must still hold it.
	if amount > rt.recapitalizable(denom, r.Incident, id) {
		return ufmt.Errorf("controls: recapitalization %d is above what incident %s still has unrecovered", id, r.Incident)
	}
	rt.closeRecap(r)
	r.Paid, r.PaidBy = true, by
	rt.recover(denom, r.Incident, amount)
	t := &rt.Denom(denom).Totals
	it := rt.incident(denom, r.Incident)
	t.Recapitalized, it.Recapitalized = statAdd(t.Recapitalized, amount), statAdd(it.Recapitalized, amount)
	return nil
}

// Reduce cuts an open or withheld claim, or an unpaid owed sweep entry, by
// amount against an incident: an explicit liability reduction (ADR pr6375
// §7.9, the claims term of §7.11 includes the sweep entries owed). The claims
// term and the unrecovered losses fall by the same amount; refunds are never
// reduced.
func (rt *Route) Reduce(key string, amount uint256, incident string) error {
	c := rt.claim(key)
	if c == nil {
		return rt.reduceSweep(key, amount, incident)
	}
	if c.State != Open && c.State != Withheld {
		return errors.New("controls: claim " + key + " is " + c.State)
	}
	d := rt.Denom(c.Denom)
	if incident == "" {
		return errors.New("controls: a reduction names its incident")
	}
	if err := rt.checkRemedy(c.Denom, incident); err != nil {
		return err
	}
	if amount == 0 || amount > c.Remaining() || amount > rt.unrecoveredOf(c.Denom, incident) {
		return ufmt.Errorf("controls: %s is not within the claim's remainder and incident %s's unrecovered losses", u(amount), incident)
	}
	rt.revokeConflicting(c.Denom, incident, amount)
	c.Amount -= amount
	c.Reduced += amount // at most the claim's amount
	rt.recover(c.Denom, incident, amount)
	it := rt.incident(c.Denom, incident)
	d.Totals.Reduced, it.Reduced = statAdd(d.Totals.Reduced, amount), statAdd(it.Reduced, amount)
	if c.State == Open {
		d.Totals.Owed = mustSub(d.Totals.Owed, amount)
		if c.Remaining() == 0 {
			c.State = Done
			rt.dequeue(d, c, d.queues.Get(string(c.To)).(*queue))
		}
	} else {
		d.Totals.Withheld = mustSub(d.Totals.Withheld, amount)
	}
	return nil
}

// reduceSweep cuts a live sweep entry: its payable amount and the swept
// term fall, and an entry cut to nothing is closed as paid by the reduction.
func (rt *Route) reduceSweep(key string, amount uint256, incident string) error {
	e := rt.sweep(key)
	if e == nil {
		return errors.New("controls: no claim or sweep entry " + key)
	}
	if e.Voided || e.Paid {
		return errors.New("controls: sweep entry " + key + " is voided or paid")
	}
	if incident == "" {
		return errors.New("controls: a reduction names its incident")
	}
	if err := rt.checkRemedy(e.Denom, incident); err != nil {
		return err
	}
	if amount == 0 || amount > e.Amount || amount > rt.unrecoveredOf(e.Denom, incident) {
		return ufmt.Errorf("controls: %s is not within the sweep entry's amount and incident %s's unrecovered losses", u(amount), incident)
	}
	rt.revokeConflicting(e.Denom, incident, amount)
	d := rt.Denom(e.Denom)
	e.Amount -= amount
	e.Reduced += amount // at most the entry's amount
	d.Totals.Swept = mustSub(d.Totals.Swept, amount)
	rt.recover(e.Denom, incident, amount)
	it := rt.incident(e.Denom, incident)
	d.Totals.Reduced, it.Reduced = statAdd(d.Totals.Reduced, amount), statAdd(it.Reduced, amount)
	if e.Amount == 0 {
		e.Paid, e.PaidTo = true, "reduced"
	}
	return nil
}

// Accept records an accepted deficit (ADR pr6375 §7.9): governance reopens
// with amount of the losses unrecovered, stated in the trust statement. The
// loss stays unrecovered (the supply identity still carries it); it only no
// longer waits for a restoring decision.
func (rt *Route) Accept(denom string, amount uint256, incident string) error {
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if incident == "" {
		return errors.New("controls: an accepted deficit names its incident")
	}
	if amount == 0 || amount > rt.unresolvedOf(denom, incident) {
		return ufmt.Errorf("controls: %s is not within incident %s's unresolved losses", u(amount), incident)
	}
	rt.accept(denom, incident, amount)
	return nil
}
