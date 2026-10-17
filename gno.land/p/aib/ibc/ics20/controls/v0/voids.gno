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
	Amount    int64
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
	Amount   int64
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
	Lost          int64
	Recapitalized int64
	Reduced       int64
	Accepted      int64
	// The outstanding balances, exact and checked (see Totals).
	OpenUnrecovered int64
	OpenUnresolved  int64
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
func (rt *Route) recapitalizable(denom, incident string, skip int64) int64 {
	it := rt.Incident(denom, incident)
	return it.OpenUnrecovered - rt.openRecaps(denom, incident, skip)
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
	losses := map[string]int64{}
	for _, k := range keys {
		if !rt.Voidable(k, forged) {
			return errors.New("controls: " + k + " cannot be voided " + voidWord(forged) + " as it stands")
		}
		denom, paid := "", int64(0)
		if c := rt.claim(k); c != nil && forged {
			denom, paid = c.Denom, c.Paid
		} else if e := rt.sweep(k); e != nil && e.Paid {
			denom, paid = e.Denom, e.Amount
		}
		if paid > 0 {
			sum, ok := checkedAdd(losses[denom], paid)
			if !ok {
				return errors.New("controls: the void's losses would overflow the loss ledger of " + denom)
			}
			losses[denom] = sum
		}
	}
	for denom, amount := range losses {
		if err := rt.lossFits(denom, incident, amount); err != nil {
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
		if e.Paid {
			// Its payout left the swept total when it was paid: what the
			// sweep decision paid is the loss, booked once.
			rt.addLoss(d, Loss{Key: k, Direction: DirRecv, Denom: e.Denom, Amount: e.Amount, Chain: ChainGno, Incident: incident, Cause: "forged payout"})
			continue
		}
		d.Totals.Swept -= e.Amount
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
		d.Totals.Owed -= rem
		rt.dequeue(d, c, d.queues.Get(string(c.To)).(*queue))
		if forged {
			c.State = Forged
		} else {
			d.Totals.Withheld = mustAdd(d.Totals.Withheld, rem)
			c.State = Withheld
		}
	case Withheld:
		d.Totals.Withheld -= rem
		c.State = Forged
	case Done:
		c.State = Forged
	}
	if forged && c.Paid > 0 {
		rt.addLoss(d, Loss{Key: c.Key, Direction: DirRecv, Denom: c.Denom, Amount: c.Paid, Chain: ChainGno, Incident: incident, Cause: "forged payout"})
	}
}

// resolve takes amount, which its caller checked is within the incident's
// unresolved losses, off the outstanding balances of the denom and the
// incident: off the unresolved ones always, off the unrecovered ones too when
// it recovers (a recapitalization or a reduction, not an accepted deficit).
func (rt *Route) resolve(denom, incident string, amount int64, recovers bool) {
	t := &rt.Denom(denom).Totals
	it := rt.incident(denom, incident)
	if amount > it.OpenUnresolved || amount > t.OpenUnresolved {
		panic("controls: a resolution beyond the unresolved losses")
	}
	t.OpenUnresolved -= amount
	it.OpenUnresolved -= amount
	if recovers {
		t.OpenUnrecovered -= amount
		it.OpenUnrecovered -= amount
	}
}

// recover takes a paid recapitalization off the outstanding balances: off
// the unrecovered losses, and off the unresolved ones as far as they go (an
// accepted deficit it restores is resolved already). Its caller checked
// amount is within the incident's unrecovered losses.
func (rt *Route) recover(denom, incident string, amount int64) {
	t := &rt.Denom(denom).Totals
	it := rt.incident(denom, incident)
	if amount > it.OpenUnrecovered || amount > t.OpenUnrecovered {
		panic("controls: a recovery beyond the unrecovered losses")
	}
	x := amount
	if x > it.OpenUnresolved {
		x = it.OpenUnresolved
	}
	t.OpenUnrecovered -= amount
	it.OpenUnrecovered -= amount
	t.OpenUnresolved -= x // the incident's unresolved part is within the denom's
	it.OpenUnresolved -= x
}

// lossFits refuses a loss the ledger's outstanding balances (the denom's and
// the incident's unrecovered losses, which bound the unresolved ones) could
// not hold without overflowing. Lifetime statistics are not checked: a
// resolved loss frees its capacity.
func (rt *Route) lossFits(denom, incident string, amount int64) error {
	d := rt.Denom(denom)
	if amount < 0 || amount > maxInt64-d.Totals.OpenUnrecovered || amount > maxInt64-rt.Incident(denom, incident).OpenUnrecovered {
		return errors.New("controls: the loss would overflow the loss ledger of " + denom)
	}
	return nil
}

// addLoss books a loss its caller checked fits (lossFits); an addition that
// would still overflow is a broken invariant and aborts.
func (rt *Route) addLoss(d *Denom, l Loss) {
	it := rt.incident(l.Denom, l.Incident)
	unrec, ok1 := checkedAdd(d.Totals.OpenUnrecovered, l.Amount)
	itUnrec, ok2 := checkedAdd(it.OpenUnrecovered, l.Amount)
	if !ok1 || !ok2 {
		panic("controls: the loss ledger would overflow")
	}
	if l.Direction != DirRecv && l.Direction != DirSend || rt.losses.Has(lossID(l.Direction, l.Key)) {
		panic("controls: a packet's loss is booked once")
	}
	rt.losses.Set(lossID(l.Direction, l.Key), &l)
	d.Totals.OpenUnrecovered, it.OpenUnrecovered = unrec, itUnrec
	d.Totals.OpenUnresolved = mustAdd(d.Totals.OpenUnresolved, l.Amount) // at most OpenUnrecovered
	it.OpenUnresolved = mustAdd(it.OpenUnresolved, l.Amount)
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
	d.Totals.Withheld -= rem
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
func (rt *Route) CreditByVote(now, height, epoch int64, key, denom string, to address, amount, lock int64) error {
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
	// The full payable amount: a credit never drops part of an entitlement
	// (a haircut goes through Reduce, against an incident).
	if amount != e.Amount || amount < d.Config.Fee {
		return ufmt.Errorf("controls: a credit by vote is the sweep entry's whole amount (%d), at least the fee (%d), not %d", e.Amount, d.Config.Fee, amount)
	}
	if d.Config.Kind == KindUnescrow && amount > lock-d.Reserved() {
		return ufmt.Errorf("controls: %d is above the free lock of %d", amount, lock-d.Reserved())
	}
	// A minted credit replaces its sweep entry within the supply already
	// booked for it: amount never exceeds the entry.
	e.Paid = true
	e.PaidTo = PaidByVote
	d.Totals.Swept -= e.Amount
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
func (rt *Route) CreditPending(now, height, epoch int64, key, denom string, to address, amount, carried, lock int64) error {
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
		return ufmt.Errorf("controls: a credit by vote is what the packet carried (%d), at least the fee (%d), not %d", carried, d.Config.Fee, amount)
	}
	if d.Config.Kind == KindUnescrow && amount > lock-d.Reserved() {
		return ufmt.Errorf("controls: %d is above the free lock of %d", amount, lock-d.Reserved())
	}
	if _, ok := checkedAdd(d.Totals.liabilities(), amount); !ok {
		return errors.New("controls: the amount would overflow what is owed")
	}
	if d.Config.Kind == KindMint && amount > d.Config.SupplyCap-d.Totals.booked() {
		return ufmt.Errorf("controls: %d would take %s past its supply cap", amount, denom)
	}
	rt.enqueue(d, now, height, epoch, key, to, amount, ByVote)
	return nil
}

// PaySweeps pays live sweep entries of one denom to an address by decision
// (ADR pr6375 §7.1: owed, paid only by a 7-day decision). For an unescrowed
// denom the total never exceeds the free lock (what open claims do not
// reserve). It books them and returns the
// payments.
func (rt *Route) PaySweeps(keys []string, to address, lock int64) ([]Payment, error) {
	if err := parseKeys(keys); err != nil {
		return nil, err
	}
	if !to.IsValid() {
		return nil, errors.New("controls: invalid recipient " + string(to))
	}
	denom := ""
	var total int64
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
		if total, ok = checkedAdd(total, e.Amount); !ok {
			return nil, errors.New("controls: the sweep payment's total would overflow")
		}
	}
	d := rt.Denom(denom)
	if d.Config.Kind == KindUnescrow && total > lock-d.Reserved() {
		return nil, ufmt.Errorf("controls: %d is above the free lock of %d", total, lock-d.Reserved())
	}
	var out []Payment
	for _, k := range keys {
		e := rt.sweep(k)
		e.Paid, e.PaidTo = true, string(to)
		d.Totals.Swept -= e.Amount
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
func (rt *Route) RecordLoss(key, denom string, amount int64, chain, incident, cause string) error {
	if _, _, ok := ParsePacketKey(key); !ok {
		return errors.New("controls: not a packet key: " + key)
	}
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if amount <= 0 {
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
	rt.addLoss(d, Loss{Key: key, Direction: dir, Denom: denom, Amount: amount, Chain: chain, Incident: incident, Cause: cause})
	return nil
}

// AuthorizeRecap records a recapitalization a decision authorized (ADR
// pr6375 §7.9): amount, at most what of the incident's losses on the denom no
// decision resolved or reserved yet, to be paid into the escrow. It returns
// the authorization's id.
func (rt *Route) AuthorizeRecap(denom string, amount int64, incident string) (int64, error) {
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
	if amount <= 0 || amount > rt.recapitalizable(denom, incident, 0) {
		return 0, ufmt.Errorf("controls: %d is not within incident %s's unrecovered losses not yet authorized", amount, incident)
	}
	rt.nRecaps++
	rt.recaps.Set(seqKey(rt.nRecaps), &Recap{ID: rt.nRecaps, Denom: denom, Amount: amount, Incident: incident})
	return rt.nRecaps, nil
}

// openRecaps is what the unpaid recapitalizations of an incident on denom
// hold, the authorization skip aside.
func (rt *Route) openRecaps(denom, incident string, skip int64) int64 {
	var n int64
	rt.recaps.Iterate("", "", func(_ string, v any) bool {
		r := v.(*Recap)
		if !r.Paid && !r.Revoked && r.ID != skip && r.Denom == denom && r.Incident == incident {
			n = boundAdd(n, r.Amount)
		}
		return false
	})
	return n
}

// unresolvedOf is what of an incident's losses on denom no decision resolved
// (recapitalized, reduced or accepted), unpaid authorizations aside.
func (rt *Route) unresolvedOf(denom, incident string) int64 {
	it := rt.Incident(denom, incident)
	return it.OpenUnresolved
}

// revokeConflicting revokes the newest unpaid recapitalization authorizations
// of an incident until a reduction of amount leaves them within what the
// incident still has unrecovered: a reduction decided later supersedes them
// (ADR pr6375 §7.9). An accepted deficit supersedes none: a recapitalization
// may still restore it. The caller checked amount fits unresolvedOf.
func (rt *Route) revokeConflicting(denom, incident string, amount int64) {
	var open []*Recap
	rt.recaps.Iterate("", "", func(_ string, v any) bool {
		r := v.(*Recap)
		if !r.Paid && !r.Revoked && r.Denom == denom && r.Incident == incident {
			open = append(open, r)
		}
		return false
	})
	for i := len(open) - 1; i >= 0 && rt.recapitalizable(denom, incident, 0) < amount; i-- {
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
func (rt *Route) Recapitalize(id int64, denom string, amount int64, by address) error {
	v := rt.recaps.Get(seqKey(id))
	if v == nil {
		return ufmt.Errorf("controls: no recapitalization %d", id)
	}
	r := v.(*Recap)
	if r.Paid || r.Revoked {
		return ufmt.Errorf("controls: recapitalization %d is paid or revoked", id)
	}
	if r.Denom != denom || r.Amount != amount {
		return ufmt.Errorf("controls: recapitalization %d is %d %s", id, r.Amount, r.Denom)
	}
	// Re-checked at payment: the incident's losses must still hold it.
	if amount > rt.recapitalizable(denom, r.Incident, id) {
		return ufmt.Errorf("controls: recapitalization %d is above what incident %s still has unrecovered", id, r.Incident)
	}
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
func (rt *Route) Reduce(key string, amount int64, incident string) error {
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
	if amount <= 0 || amount > c.Remaining() || amount > rt.unresolvedOf(c.Denom, incident) {
		return ufmt.Errorf("controls: %d is not within the claim's remainder and incident %s's unresolved losses", amount, incident)
	}
	rt.revokeConflicting(c.Denom, incident, amount)
	c.Amount -= amount
	c.Reduced += amount // at most the claim's amount
	rt.resolve(c.Denom, incident, amount, true)
	it := rt.incident(c.Denom, incident)
	d.Totals.Reduced, it.Reduced = statAdd(d.Totals.Reduced, amount), statAdd(it.Reduced, amount)
	if c.State == Open {
		d.Totals.Owed -= amount
		if c.Remaining() == 0 {
			c.State = Done
			rt.dequeue(d, c, d.queues.Get(string(c.To)).(*queue))
		}
	} else {
		d.Totals.Withheld -= amount
	}
	return nil
}

// reduceSweep cuts a live sweep entry: its payable amount and the swept
// term fall, and an entry cut to nothing is closed as paid by the reduction.
func (rt *Route) reduceSweep(key string, amount int64, incident string) error {
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
	if amount <= 0 || amount > e.Amount || amount > rt.unresolvedOf(e.Denom, incident) {
		return ufmt.Errorf("controls: %d is not within the sweep entry's amount and incident %s's unresolved losses", amount, incident)
	}
	rt.revokeConflicting(e.Denom, incident, amount)
	d := rt.Denom(e.Denom)
	e.Amount -= amount
	e.Reduced += amount // at most the entry's amount
	d.Totals.Swept -= amount
	rt.resolve(e.Denom, incident, amount, true)
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
func (rt *Route) Accept(denom string, amount int64, incident string) error {
	d := rt.Denom(denom)
	if d == nil {
		return errors.New("controls: denom " + denom + " is not enabled on route " + rt.Key)
	}
	if incident == "" {
		return errors.New("controls: an accepted deficit names its incident")
	}
	if amount <= 0 || amount > rt.unresolvedOf(denom, incident) {
		return ufmt.Errorf("controls: %d is not within incident %s's unresolved losses", amount, incident)
	}
	rt.resolve(denom, incident, amount, false)
	it := rt.incident(denom, incident)
	d.Totals.Accepted, it.Accepted = statAdd(d.Totals.Accepted, amount), statAdd(it.Accepted, amount)
	return nil
}
