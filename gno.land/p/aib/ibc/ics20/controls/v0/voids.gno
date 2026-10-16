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
	Key      string // packet key
	Denom    string
	Amount   int64
	Chain    string
	Incident string
	Cause    string // "forged payout", or the reconciliation outcome's words
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
}

func lossKey(key, cause string) string { return key + "|" + cause }

// IncidentTotals is the loss ledger of one incident on one denom: what it
// lost and how much of that each restoring decision resolved. Resolutions of
// an incident never exceed its losses, and an authorized recapitalization not
// yet paid holds its part (ADR pr6375 §7.9).
type IncidentTotals struct {
	Lost          int64
	Recapitalized int64
	Reduced       int64
	Accepted      int64
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

// resolvable is what of an incident's losses on denom no decision resolved
// or reserved yet: its losses minus what was recapitalized, reduced or
// accepted, minus the recapitalizations authorized and not paid (except
// skip, an authorization being paid).
func (rt *Route) resolvable(denom, incident string, skip int64) int64 {
	it := rt.Incident(denom, incident)
	return it.Lost - it.Recapitalized - it.Reduced - it.Accepted - rt.openRecaps(denom, incident, skip)
}

// Voidable reports whether a void as forged (or as withheld) can take the
// claim or sweep entry of key as it stands: an open claim either way, a
// withheld or paid claim as forged only, a live sweep entry as forged only.
func (rt *Route) Voidable(key string, forged bool) bool {
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
		return forged && !e.Voided && !e.Paid
	}
	return false
}

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
		if c := rt.claim(k); c != nil && forged {
			losses[c.Denom] += c.Paid // each at most a claim's amount: no overflow per key
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
		rt.Denom(e.Denom).Totals.Swept -= e.Amount
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
			d.Totals.Withheld += rem
			c.State = Withheld
		}
	case Withheld:
		d.Totals.Withheld -= rem
		c.State = Forged
	case Done:
		c.State = Forged
	}
	if forged && c.Paid > 0 {
		rt.addLoss(d, Loss{Key: c.Key, Denom: c.Denom, Amount: c.Paid, Chain: ChainGno, Incident: incident, Cause: "forged payout"})
	}
}

// lossFits refuses a loss the ledger's cumulative totals (the denom's and
// the incident's) could not hold without overflowing: a total that wrapped
// would read as no loss at all.
func (rt *Route) lossFits(denom, incident string, amount int64) error {
	d := rt.Denom(denom)
	if amount < 0 || amount > maxInt64-d.Totals.Lost || amount > maxInt64-rt.Incident(denom, incident).Lost {
		return errors.New("controls: the loss would overflow the loss ledger of " + denom)
	}
	return nil
}

func (rt *Route) addLoss(d *Denom, l Loss) {
	rt.losses.Set(lossKey(l.Key, l.Cause), &l)
	d.Totals.Lost += l.Amount
	rt.incident(l.Denom, l.Incident).Lost += l.Amount
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
	d.Totals.Owed += rem
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
// again. The amount is at least the fee, at most what the packet carried,
// and for an unescrowed denom never above the free lock.
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
	if amount < d.Config.Fee || amount > e.Amount {
		return ufmt.Errorf("controls: %d is not between the fee (%d) and what the packet carried (%d)", amount, d.Config.Fee, e.Amount)
	}
	if d.Config.Kind == KindUnescrow && amount > lock-d.Reserved() {
		return ufmt.Errorf("controls: %d is above the free lock of %d", amount, lock-d.Reserved())
	}
	// A minted credit replaces its sweep entry within the supply already
	// booked for it: amount never exceeds the entry.
	e.Paid = true
	e.PaidTo = "credit by vote"
	d.Totals.Swept -= e.Amount
	rt.enqueue(d, now, height, epoch, key, to, amount, ByVote)
	return nil
}

// CreditPending credits by decision a packet received on the route whose
// asynchronous acknowledgement is still unwritten (ADR pr6375 §7.9): the
// caller checked that the core received it after the route's activation and
// writes its success acknowledgement in the same transaction, so the packet
// can never be refunded at its source. Nothing was booked at its receipt, so
// it has no claim or sweep entry; carried is what the packet carried. The
// amount is at least the fee and at most carried; for an unescrowed denom it
// is never above the free lock, for a minted one never past the supply cap.
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
	if amount < d.Config.Fee || amount > carried {
		return ufmt.Errorf("controls: %d is not between the fee (%d) and what the packet carried (%d)", amount, d.Config.Fee, carried)
	}
	if d.Config.Kind == KindUnescrow && amount > lock-d.Reserved() {
		return ufmt.Errorf("controls: %d is above the free lock of %d", amount, lock-d.Reserved())
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
		total += e.Amount
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
		d.Totals.SweepPaid += e.Amount
		if d.Config.Kind == KindMint {
			d.Totals.Outstanding += e.Amount
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
	if rt.losses.Has(lossKey(key, cause)) {
		return errors.New("controls: this loss is recorded already")
	}
	if err := rt.lossFits(denom, incident, amount); err != nil {
		return err
	}
	rt.addLoss(d, Loss{Key: key, Denom: denom, Amount: amount, Chain: chain, Incident: incident, Cause: cause})
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
	if amount <= 0 || amount > rt.resolvable(denom, incident, 0) {
		return 0, ufmt.Errorf("controls: %d is not within incident %s's losses not yet resolved or authorized", amount, incident)
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
		if !r.Paid && r.ID != skip && r.Denom == denom && r.Incident == incident {
			n += r.Amount
		}
		return false
	})
	return n
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
	if r.Paid {
		return ufmt.Errorf("controls: recapitalization %d is paid already", id)
	}
	if r.Denom != denom || r.Amount != amount {
		return ufmt.Errorf("controls: recapitalization %d is %d %s", id, r.Amount, r.Denom)
	}
	// Re-checked at payment: the incident's losses must still hold it.
	if amount > rt.resolvable(denom, r.Incident, id) {
		return ufmt.Errorf("controls: recapitalization %d is above what incident %s still has to resolve", id, r.Incident)
	}
	r.Paid, r.PaidBy = true, by
	rt.Denom(denom).Totals.Recapitalized += amount
	rt.incident(denom, r.Incident).Recapitalized += amount
	return nil
}

// Reduce cuts an open or withheld claim by amount against an incident: an
// explicit liability reduction (ADR pr6375 §7.9). The claims term and the
// unrecovered losses fall by the same amount; refunds are never reduced.
func (rt *Route) Reduce(key string, amount int64, incident string) error {
	c := rt.claim(key)
	if c == nil {
		return errors.New("controls: no claim " + key)
	}
	if c.State != Open && c.State != Withheld {
		return errors.New("controls: claim " + key + " is " + c.State)
	}
	d := rt.Denom(c.Denom)
	if incident == "" {
		return errors.New("controls: a reduction names its incident")
	}
	if amount <= 0 || amount > c.Remaining() || amount > rt.resolvable(c.Denom, incident, 0) {
		return ufmt.Errorf("controls: %d is not within the claim's remainder and incident %s's losses not yet resolved or authorized", amount, incident)
	}
	c.Amount -= amount
	c.Reduced += amount
	d.Totals.Reduced += amount
	rt.incident(c.Denom, incident).Reduced += amount
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
	if amount <= 0 || amount > rt.resolvable(denom, incident, 0) {
		return ufmt.Errorf("controls: %d is not within incident %s's losses not yet resolved or authorized", amount, incident)
	}
	d.Totals.Accepted += amount
	rt.incident(denom, incident).Accepted += amount
	return nil
}
