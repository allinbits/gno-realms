package controls

import (
	"errors"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Send outcomes, attached by the acknowledgement and timeout callbacks.
const (
	OutcomePending = ""        // in flight: no acknowledgement or timeout processed yet
	OutcomeSuccess = "success" // a success acknowledgement
	OutcomeError   = "error"   // an error acknowledgement: refunded
	OutcomeTimeout = "timeout" // a timeout: refunded
)

// Payment states of a send record (ADR pr6375 §7.13).
const (
	PayNone       = ""           // nothing owed: in flight, or acknowledged as a success
	PayPaid       = "paid"       // refunded at once
	PayQueued     = "queued"     // refund owed, waiting under the refund meter, a refunds hold or the minted supply's headroom
	PayClaimed    = "claimed"    // a queued refund paid in full later
	PayRejected   = "rejected"   // a queued refund a reconciliation settled unpaid
	PayReconciled = "reconciled" // a refund a reconciliation paid by decision
)

// SendRecord is the immutable record of one send, written by the send entry
// point in the same transaction as the send (ADR pr6375 §7.13): the full
// packet (timeout and payload included), its commitment and the send's
// metadata. The acknowledgement and timeout callbacks only attach the outcome,
// the local processing height and the payment state. A reconciliation (§7.12)
// authenticates a packet whose commitment its processing deleted by this
// record.
type SendRecord struct {
	Key        string // packet key: source client / sequence
	Packet     types.Packet
	Commitment []byte // types.CommitPacket(Packet)
	Sender     address
	Receiver   string
	Denom      string // the accounting denom: escrow denom or voucher IBC denom
	Kind       string // KindUnescrow (escrowed) or KindMint (burned)
	Amount     int64
	Fee        int64 // charged on top of Amount, paid to the collector
	SentHeight int64
	SentAt     int64

	Outcome         string
	ProcessedHeight int64
	ProcessedAt     int64
	Payment         string
	Refunded        int64  // what was refunded so far, at once, by claims or by decision
	Settlement      uint8  // the reconciliation's action (SettlePay...), 0 while unsettled
	Reservation     int64  // KindMint: the supply this send still holds against the cap, released or consumed once
	Proven          uint8  // the destination's outcome, proven through the replacement client (ProvenDelivered...)
	ProvenBy        string // the client that verified it: the outcome is void once it is no longer Active
	ProvenAt        uint64 // the proof's height on the replacement client
	ProvenGen       uint64 // ProvenBy's trust generation then: void once a recovery, freeze, upgrade, migration or substitution starts another
	ProvenReserve   int64  // what its proven refund reserves (ProvenOwed) until it settles: a send a forged success released, proven refundable
	Incident        string
}

func copyPacket(p types.Packet) types.Packet {
	out := p
	out.Payloads = make([]types.Payload, len(p.Payloads))
	for i, pl := range p.Payloads {
		pl.Value = append([]byte{}, pl.Value...)
		out.Payloads[i] = pl
	}
	return out
}

// RecordSend writes a send's record and books the send: it escrowed the
// amount (KindUnescrow) or burned it (KindMint, lowering the outstanding
// vouchers). The packet and the commitment are copied, so the caller keeps no
// alias into the record. A key is written once.
func (rt *Route) RecordSend(rec SendRecord) error {
	if _, _, ok := ParsePacketKey(rec.Key); !ok {
		return errors.New("controls: not a packet key: " + rec.Key)
	}
	if rt.sends.Has(rec.Key) {
		return errors.New("controls: a send record exists for " + rec.Key)
	}
	d := rt.Denom(rec.Denom)
	if d == nil {
		return errors.New("controls: denom " + rec.Denom + " is not enabled on route " + rt.Key)
	}
	if rec.Kind != d.Config.Kind {
		return errors.New("controls: the send's accounting differs from its denom's")
	}
	if rec.Amount <= 0 || rec.Fee < 0 {
		return errors.New("controls: invalid send amounts")
	}
	// Every refund a send may still owe is bounded by the open records'
	// amounts: a send that would overflow them is refused.
	if _, ok := checkedAdd(d.Totals.InFlight, rec.Amount); !ok {
		return errors.New("controls: the route's open sends of " + rec.Denom + " would overflow")
	}
	r := rec
	r.Packet = copyPacket(rec.Packet)
	r.Commitment = append([]byte{}, rec.Commitment...)
	r.Outcome, r.ProcessedHeight, r.ProcessedAt, r.Payment, r.Refunded, r.Settlement, r.Incident = OutcomePending, 0, 0, PayNone, 0, 0, ""
	r.Reservation = 0
	rt.sends.Set(r.Key, &r)
	rt.track(&r, false)
	rt.addPending(r.Key, 1)
	d.Totals.Sent = statAdd(d.Totals.Sent, r.Amount)
	d.Totals.SendFees = statAdd(d.Totals.SendFees, r.Fee)
	if d.Config.Kind == KindMint {
		// The burned vouchers leave circulation but stay counted against
		// the supply cap until the send settles: a refund mints them again.
		d.Totals.Outstanding -= r.Amount
		if d.Totals.Outstanding < 0 {
			// vouchers minted before the route was controlled
			d.Totals.Outstanding = 0
		}
		r.Reservation = r.Amount
		d.Totals.Returning = mustAdd(d.Totals.Returning, r.Amount) // at most InFlight
	}
	return nil
}

// isOpen reports whether a send record is still open (ADR pr6375 §5.4 kind
// 13): no reconciliation settled it, and its outcome is pending (the
// commitment outstanding) or its refund is queued.
func isOpen(r *SendRecord) bool {
	return r.Settlement == 0 && (r.Outcome == OutcomePending || r.Payment == PayQueued)
}

// track updates the count of open records of r's client after a change to r,
// which was open (was) before it.
func (rt *Route) track(r *SendRecord, was bool) {
	now := isOpen(r)
	if now == was {
		return
	}
	d := rt.Denom(r.Denom)
	if now {
		d.Totals.InFlight = mustAdd(d.Totals.InFlight, r.Amount) // checked when recorded
	} else {
		d.Totals.InFlight -= r.Amount
	}
	client, _, _ := ParsePacketKey(r.Key)
	var n int64
	if v := rt.openSends.Get(client); v != nil {
		n = v.(int64)
	}
	if now {
		n++
	} else {
		n--
	}
	if n == 0 {
		rt.openSends.Remove(client)
	} else {
		rt.openSends.Set(client, n)
	}
	rt.reblock(client)
}

// processedSet is a client's send records that were processed (an
// acknowledgement or a timeout attached) and are not settled by
// reconciliation, ordered by processing height: the records processed at or
// after a height are counted in logarithmic work (ADR pr6375 §7.12).
type processedSet struct {
	root *avl.Node // processedKey -> true
}

func processedKey(height int64, key string) string { return seqKey(height) + "|" + key }

func (rt *Route) processedOf(client string, create bool) *processedSet {
	if v := rt.processed.Get(client); v != nil {
		return v.(*processedSet)
	}
	if !create {
		return nil
	}
	ps := &processedSet{}
	rt.processed.Set(client, ps)
	return ps
}

// markProcessed adds a record whose outcome was just attached.
func (rt *Route) markProcessed(r *SendRecord) {
	client, _, _ := ParsePacketKey(r.Key)
	ps := rt.processedOf(client, true)
	ps.root, _ = ps.root.Set(processedKey(r.ProcessedHeight, r.Key), true)
	rt.reblock(client)
}

// unmarkProcessed removes a record a reconciliation settled.
func (rt *Route) unmarkProcessed(r *SendRecord) {
	if r.Outcome == OutcomePending {
		return
	}
	client, _, _ := ParsePacketKey(r.Key)
	if ps := rt.processedOf(client, false); ps != nil {
		ps.root, _, _, _ = ps.root.Remove(processedKey(r.ProcessedHeight, r.Key))
	}
	rt.reblock(client)
}

// SuspectUnsettled is how many send records of a retired client were
// processed at or after the replacement's suspect height and are not settled
// by reconciliation; 0 for a client no replacement retired.
func (rt *Route) SuspectUnsettled(clientID string) int64 {
	v := rt.suspect.Get(clientID)
	ps := rt.processedOf(clientID, false)
	if v == nil || ps == nil {
		return 0
	}
	below, _, _ := ps.root.Get(seqKey(v.(int64)))
	return int64(ps.root.Size() - below)
}

// OpenSends is how many send records of clientID are still open.
func (rt *Route) OpenSends(clientID string) int64 {
	if v := rt.openSends.Get(clientID); v != nil {
		return v.(int64)
	}
	return 0
}

// release ends a minted send's supply reservation, once: the record owes no
// more refund (a success, a rejected refund, a reconciliation's settlement),
// so what was not refunded stays burned. A record released already releases
// nothing more.
func (rt *Route) release(d *Denom, r *SendRecord) {
	d.Totals.Returning -= r.Reservation
	r.Reservation = 0
}

// Send is the send record of a packet key, by value (the packet copied), and
// whether it exists.
func (rt *Route) Send(key string) (SendRecord, bool) {
	r := rt.send(key)
	if r == nil {
		return SendRecord{}, false
	}
	c := *r
	c.Packet = copyPacket(r.Packet)
	c.Commitment = append([]byte{}, r.Commitment...)
	return c, true
}

func (rt *Route) send(key string) *SendRecord {
	v := rt.sends.Get(key)
	if v == nil {
		return nil
	}
	return v.(*SendRecord)
}

// Settle attaches an acknowledgement's or a timeout's outcome to a send record
// at the local processing height. A success owes nothing. An error or a
// timeout owes a refund of the amount minus what a reconciliation already
// paid on it (the fee is not refunded): paid at once when no refunds hold
// stands, no refund of the denom is queued ahead, the refund meter holds it
// and, for an unescrowed denom, the lock (the escrow) covers it; queued
// otherwise, to be paid by PayRefunds. lock is ignored for a minted denom. It
// returns what to refund now (0 when queued). A record is settled once.
func (rt *Route) Settle(now, height int64, key, outcome string, hold bool, lock int64) (int64, error) {
	r := rt.send(key)
	if r == nil {
		return 0, errors.New("controls: no send record for " + key)
	}
	if r.Outcome != OutcomePending {
		return 0, errors.New("controls: send " + key + " is settled already (" + r.Outcome + ")")
	}
	if outcome != OutcomeSuccess && outcome != OutcomeError && outcome != OutcomeTimeout {
		return 0, errors.New("controls: unknown outcome " + outcome)
	}
	d := rt.Denom(r.Denom)
	defer rt.track(r, isOpen(r))
	rt.addPending(r.Key, -1)
	r.Outcome, r.ProcessedHeight, r.ProcessedAt = outcome, height, now
	if r.Settlement == 0 {
		rt.markProcessed(r)
	}
	if r.Settlement != 0 {
		return 0, nil // a reconciliation settled it: nothing more moves, nothing is paid
	}
	owed := r.Amount - r.Refunded
	if outcome == OutcomeSuccess {
		rt.release(d, r)
		return 0, nil
	}
	if owed <= 0 {
		return 0, nil
	}
	// A minted refund mints the vouchers again: paid at once only within the
	// outstanding supply's headroom, otherwise queued.
	_, fits := checkedAdd(d.Totals.Outstanding, owed)
	covered := d.Config.Kind == KindMint && fits || d.Config.Kind == KindUnescrow && lock >= owed
	d.refundMeter.Refill(now, d.Config.RefundCap, d.Config.RefundCap, 0, 0)
	if !hold && covered && d.refundQueue.Size() == 0 && d.refundMeter.Level >= owed {
		d.refundMeter.Take(owed)
		rt.refunded(d, r, owed)
		r.Payment = PayPaid
		return owed, nil
	}
	d.queueRefund(key, owed)
	r.Payment = PayQueued
	return 0, nil
}

// queueRefund appends the refund of the send key, amount owed, to the denom's
// refund queue, indexed by key so it leaves the queue in logarithmic work.
func (d *Denom) queueRefund(key string, amount int64) {
	d.refundSeq++
	k := seqKey(d.refundSeq)
	d.refundQueue.Set(k, key)
	d.refundIdx.Set(key, k)
	d.Totals.QueuedRefunds = mustAdd(d.Totals.QueuedRefunds, amount) // at most InFlight, or reserved by a settlement
}

// refunded books amount refunded on r.
func (rt *Route) refunded(d *Denom, r *SendRecord, amount int64) {
	r.Refunded += amount // at most the record's amount
	d.Totals.Refunded = statAdd(d.Totals.Refunded, amount)
	if d.Config.Kind == KindMint {
		// The burned vouchers are minted again: back in circulation. They
		// consume what the send still reserves, and no more: a refund a
		// reconciliation pays after the reservation was released (a forged
		// success) mints vouchers no reservation held.
		d.Totals.Outstanding = mustAdd(d.Totals.Outstanding, amount)
		consumed := amount
		if consumed > r.Reservation {
			consumed = r.Reservation
		}
		r.Reservation -= consumed
		if r.Settlement != 0 {
			d.Totals.Parked -= consumed // a settlement's parked refund
		} else {
			d.Totals.Returning -= consumed
		}
	}
}

// RefundPayment is what a refund moves to the sender: Amount out of the
// denom's escrow (KindUnescrow) or as minted vouchers (KindMint).
type RefundPayment struct {
	Key    string
	Denom  string
	To     address
	Amount int64
}

// PayRefunds pays up to n queued refunds of a denom, oldest first, as the
// refund meter allows (ADR pr6375 §7.13): a refund is paid in installments,
// each at least min(what it still owes, an hour of the refund cap), and the
// queue stops at the first refund the meter, or for an unescrowed denom the
// lock (the escrow), cannot serve. A refunds hold pays nothing. It books the payments and returns them.
func (rt *Route) PayRefunds(now int64, denom string, n int, hold bool, lock int64) ([]RefundPayment, error) {
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
	if hold {
		return nil, nil
	}
	d.refundMeter.Refill(now, d.Config.RefundCap, d.Config.RefundCap, 0, 0)
	// The escrow proven refunds reserve is theirs: a queued refund never
	// takes it.
	lock -= d.Totals.ProvenOwed
	var out []RefundPayment
	for len(out) < n {
		k, key, ok := d.headRefund()
		if !ok {
			break
		}
		r := rt.send(key)
		rem := r.Amount - r.Refunded
		need := d.Config.RefundCap / 24
		if need < 1 {
			need = 1
		}
		if need > rem {
			need = rem
		}
		if d.refundMeter.Level < need {
			break
		}
		pay := rem
		if pay > d.refundMeter.Level {
			pay = d.refundMeter.Level
		}
		if d.Config.Kind == KindUnescrow {
			if pay > lock {
				pay = lock
			}
			if pay < need {
				break
			}
			lock -= pay
		}
		// A minted installment stays within the outstanding supply's
		// headroom, whatever it is (a parked refund may be larger than any
		// headroom a return frees); the remainder waits.
		if room := maxInt64 - d.Totals.Outstanding; d.Config.Kind == KindMint && pay > room {
			pay = room
			if pay < 1 {
				break
			}
		}
		d.refundMeter.Take(pay)
		was := isOpen(r)
		rt.refunded(d, r, pay)
		d.Totals.QueuedRefunds -= pay
		if r.Refunded == r.Amount {
			d.refundQueue.Remove(k)
			d.refundIdx.Remove(key)
			r.Payment = PayClaimed
			if r.Settlement != 0 {
				r.Payment = PayReconciled // a settlement's parked refund
			}
			rt.track(r, was)
		}
		out = append(out, RefundPayment{Key: key, Denom: denom, To: r.Sender, Amount: pay})
	}
	return out, nil
}

func (d *Denom) headRefund() (string, string, bool) {
	var k, key string
	found := false
	d.refundQueue.Iterate("", "", func(kk string, v any) bool {
		k, key, found = kk, v.(string), true
		return true
	})
	return k, key, found
}

// QueuedRefundCount is how many refunds of a denom wait.
func (rt *Route) QueuedRefundCount(denom string) int {
	d := rt.Denom(denom)
	if d == nil {
		return 0
	}
	return d.refundQueue.Size()
}

// Settlement actions of a reconciliation (ADR pr6375 §5.4 kind 12, §7.12),
// one per send record, the same numbers as on Ethereum.
const (
	SettlePay           = uint8(1) // a genuine refund: pay its whole remainder, Amount = what the packet carried minus what was refunded (0 if paid in full)
	SettleReject        = uint8(2) // reject a queued refund, none of it paid: the packet was delivered
	SettleDelivered     = uint8(3) // the packet was delivered, no refund paid: settled, nothing owed (a queued refund is rejected)
	SettleLoss          = uint8(4) // a forged refund: the unpaid remainder rejected, what was paid (Amount) recorded as a loss
	SettleForgedReceive = uint8(5) // a forged receive: Seq is an inbound sequence; its claim is forged (remainder dropped), what it paid out (Amount) a loss, once
)

// Proven outcomes of a send, read from its destination through the route's
// replacement client (ADR pr6375 §7.12 "Proven outcomes"): a settlement's
// action must match.
const (
	ProvenNone       = uint8(0)
	ProvenDelivered  = uint8(1) // the receipt is the packet's and its acknowledgement a success
	ProvenRefundable = uint8(2) // no receipt, or the packet's receipt with an error acknowledgement
	ProvenCollision  = uint8(3) // another packet's receipt occupies the sequence: the packet is refundable
)

// CauseForgedReceive is the cause of a forged receive's loss.
const CauseForgedReceive = "forged-receive"

// SettleItem is one reconciliation outcome: the send at Seq of the settled
// client.
type SettleItem struct {
	Seq    uint64
	Action uint8
	Amount int64
}

// SettleRecords applies a reconciliation's outcomes to the send records of
// client, a client a replacement retired from the route (ADR pr6375 §7.12):
// every record named is settled exactly once, after which no acknowledgement,
// timeout or decision moves it again. A queued refund leaves the queue under
// any action, paid only by SettlePay. lock is the escrow of an unescrowed
// denom: payments never take what open claims reserve. Every item is checked
// before anything changes. It returns the refunds to pay. trusted reports
// whether a verifier still vouches for what it proved under a trust
// generation: Active, not retired, and that generation still current.
func (rt *Route) SettleRecords(client string, items []SettleItem, incident string, lock func(denom string) int64, trusted func(client string, gen uint64) bool) ([]RefundPayment, error) {
	plan, err := rt.PlanSettlement(client, items, incident, lock, nil, trusted)
	if err != nil {
		return nil, err
	}
	return rt.ApplySettlement(plan), nil
}

// SettlePlan is a checked settlement, not applied yet: the refunds it pays
// at once (Payments) and the minted refunds it parks. It holds for the
// state it was planned on: apply it in the same transaction, nothing
// changed in between.
type SettlePlan struct {
	client, incident string
	items            []SettleItem
	parked           map[uint64]bool // outbound sequences whose refund is parked
	// Payments are the refunds the settlement pays at once, in item order.
	Payments []RefundPayment
}

// Parked lists the outbound sequences whose minted refund the plan parks.
func (p *SettlePlan) Parked() []uint64 {
	var out []uint64
	for _, it := range p.items {
		if p.parked[it.Seq] && it.Action == SettlePay {
			out = append(out, it.Seq)
		}
	}
	return out
}

// PlanSettlement checks a reconciliation's outcomes (see SettleRecords) and
// plans them without changing anything: which genuine refunds are paid at
// once and which minted ones are parked, the supply then holding no room for
// them. room is the room left for minting a denom (nil: what its outstanding
// supply leaves under int64; a caller also bound by a token's supply passes
// the lower of the two): the refunds take it in item order, and one that
// does not fit is parked. The parked refunds are checked against their own
// total (Parked), apart from the in-flight burns' reservations (Returning),
// and the queued refunds net of what the batch unqueues.
func (rt *Route) PlanSettlement(client string, items []SettleItem, incident string, lock func(denom string) int64, room func(denom string) int64, trusted func(client string, gen uint64) bool) (*SettlePlan, error) {
	retired := false
	for _, c := range rt.Replaced {
		if c == client {
			retired = true
		}
	}
	if !retired {
		return nil, errors.New("controls: " + client + " is no client a replacement retired from route " + rt.Key + ": only its sends are settled by reconciliation")
	}
	if len(items) == 0 || len(items) > MaxKeys {
		return nil, ufmt.Errorf("controls: settle 1 to %d sends", MaxKeys)
	}
	if incident == "" {
		return nil, errors.New("controls: a settlement names its incident")
	}
	seen := map[uint64]bool{}
	seenIn := map[uint64]bool{}
	pays := map[string]int64{}
	// What the batch takes off each liability that reserves the escrow,
	// whatever the items' order: every settled record's queued refund (each
	// action unqueues it), and every forged receive's unpaid claim remainder
	// (owed or withheld). The payments are checked against the escrow the
	// liabilities still reserve once the whole batch applies; each is exact
	// on its own, so the subtraction happens before any saturating sum.
	relQueued, relOwed, relWithheld, relProven := map[string]int64{}, map[string]int64{}, map[string]int64{}, map[string]int64{}
	lossTotals := map[string]int64{}
	for i, it := range items {
		key := PacketKey(client, it.Seq)
		if it.Action == SettleForgedReceive {
			if it.Seq == 0 || seenIn[it.Seq] {
				return nil, ufmt.Errorf("controls: item %d: no sequence, or named twice", i)
			}
			seenIn[it.Seq] = true
			denom, paid, err := rt.forgedReceive(key)
			if err != nil {
				return nil, ufmt.Errorf("controls: item %d: %v", i, err)
			}
			if it.Amount <= 0 || it.Amount != paid {
				return nil, ufmt.Errorf("controls: item %d: the receive %s paid out %d, not %d", i, key, paid, it.Amount)
			}
			var ok bool
			if lossTotals[denom], ok = checkedAdd(lossTotals[denom], it.Amount); !ok {
				return nil, ufmt.Errorf("controls: item %d: the settlement's losses overflow", i)
			}
			if c := rt.claim(key); c != nil {
				switch c.State {
				case Open:
					relOwed[denom] += c.Remaining() // within Owed
				case Withheld:
					relWithheld[denom] += c.Remaining() // within Withheld
				}
			}
			continue
		}
		r := rt.send(key)
		switch {
		case it.Seq == 0 || seen[it.Seq]:
			return nil, ufmt.Errorf("controls: item %d: no sequence, or named twice", i)
		case r == nil:
			return nil, ufmt.Errorf("controls: item %d: no send record for %s", i, key)
		case r.Settlement != 0:
			return nil, ufmt.Errorf("controls: item %d: send %s is settled already", i, key)
		}
		seen[it.Seq] = true
		relProven[r.Denom] += r.ProvenReserve // within ProvenOwed
		if r.Payment == PayQueued {
			relQueued[r.Denom] += r.Amount - r.Refunded // within QueuedRefunds
		}
		// The action must match the outcome proven through the replacement
		// client (ADR pr6375 §7.12): governance chooses, the proof decides.
		switch {
		case r.Proven != ProvenNone && !trusted(r.ProvenBy, r.ProvenGen):
			return nil, ufmt.Errorf("controls: item %d: send %s's outcome was proven through %s under trust generation %d, no longer Active or current: prove it again", i, key, r.ProvenBy, r.ProvenGen)
		case (it.Action == SettlePay) && r.Proven != ProvenRefundable && r.Proven != ProvenCollision,
			(it.Action == SettleReject || it.Action == SettleDelivered || it.Action == SettleLoss) && r.Proven != ProvenDelivered:
			return nil, ufmt.Errorf("controls: item %d: action %d does not match send %s's proven outcome (%d)", i, it.Action, key, r.Proven)
		}
		switch it.Action {
		case SettlePay:
			// A genuine refund: its whole remainder, never cut short (ADR
			// pr6375 §7.9); zero for one paid in full already, which only
			// settles the record.
			if it.Amount != r.Amount-r.Refunded {
				return nil, ufmt.Errorf("controls: item %d: a refund pays send %s's whole remainder (%d), not %d", i, key, r.Amount-r.Refunded, it.Amount)
			}
			if it.Amount == 0 {
				break // paid in full already: settles the record, moves nothing
			}
			var ok bool
			if pays[r.Denom], ok = checkedAdd(pays[r.Denom], it.Amount); !ok {
				return nil, ufmt.Errorf("controls: item %d: the settlement's payments overflow", i)
			}
		case SettleReject:
			if r.Payment != PayQueued || it.Amount != 0 {
				return nil, ufmt.Errorf("controls: item %d: send %s has no queued refund, or names an amount", i, key)
			}
			if r.Refunded > 0 {
				return nil, ufmt.Errorf("controls: item %d: send %s was refunded in part already: a delivered packet's paid refund is a forged refund (action 4)", i, key)
			}
		case SettleDelivered:
			if it.Amount != 0 {
				return nil, ufmt.Errorf("controls: item %d: a delivered send names no amount", i)
			}
			if r.Refunded > 0 {
				return nil, ufmt.Errorf("controls: item %d: send %s was refunded: a delivered packet's paid refund is a forged refund (action 4)", i, key)
			}
		case SettleLoss:
			// A forged refund: what was paid is the loss, the remainder is
			// rejected.
			if r.Refunded <= 0 || it.Amount != r.Refunded {
				return nil, ufmt.Errorf("controls: item %d: a forged refund's loss is what send %s was refunded (%d), not %d", i, key, r.Refunded, it.Amount)
			}
			if rt.LossBooked(DirSend, key) {
				return nil, ufmt.Errorf("controls: item %d: the loss of %s is recorded already", i, key)
			}
			var ok bool
			if lossTotals[r.Denom], ok = checkedAdd(lossTotals[r.Denom], it.Amount); !ok {
				return nil, ufmt.Errorf("controls: item %d: the settlement's losses overflow", i)
			}
		default:
			return nil, ufmt.Errorf("controls: item %d: unknown action %d", i, it.Action)
		}
	}
	for denom, total := range lossTotals {
		if err := rt.lossFits(denom, incident, total); err != nil {
			return nil, err
		}
	}
	plan := &SettlePlan{client: client, incident: incident, items: items, parked: map[uint64]bool{}}
	// The minted refunds take the room left for minting, in item order; one
	// that does not fit is parked, owed and reserved (see park).
	left := map[string]int64{}
	parkedTotal := map[string]int64{}
	for _, it := range items {
		if it.Action != SettlePay || it.Amount <= 0 {
			continue
		}
		r := rt.send(PacketKey(client, it.Seq))
		d := rt.Denom(r.Denom)
		if d.Config.Kind == KindMint {
			if _, ok := left[r.Denom]; !ok {
				left[r.Denom] = maxInt64 - d.Totals.Outstanding
				if room != nil {
					if x := room(r.Denom); x < left[r.Denom] {
						left[r.Denom] = x
					}
				}
			}
			if it.Amount > left[r.Denom] {
				plan.parked[it.Seq] = true
				parkedTotal[r.Denom] += it.Amount // within the denom's settled amounts, checked above
				continue
			}
			left[r.Denom] -= it.Amount
		}
		plan.Payments = append(plan.Payments, RefundPayment{Key: r.Key, Denom: r.Denom, To: r.Sender, Amount: it.Amount})
	}
	// Net of what the batch releases, the parked refunds' reservations and
	// queue entries must fit.
	for denom, parked := range parkedTotal {
		d := rt.Denom(denom)
		if _, ok := checkedAdd(d.Totals.Parked, parked); !ok {
			return nil, errors.New("controls: the parked refunds would overflow the parked total of " + denom)
		}
		if _, ok := checkedAdd(d.Totals.QueuedRefunds-relQueued[denom], parked); !ok {
			return nil, errors.New("controls: the parked refunds would overflow the queued refunds of " + denom)
		}
	}
	for denom, total := range pays {
		d := rt.Denom(denom)
		if d.Config.Kind == KindMint {
			continue
		}
		// The escrow the liabilities still reserve once the whole batch
		// applies: claims and queued refunds, less what the batch releases.
		reserved := boundAdd(boundAdd(boundAdd(d.Totals.Owed-relOwed[denom], d.Totals.Withheld-relWithheld[denom]), d.Totals.QueuedRefunds-relQueued[denom]), d.Totals.ProvenOwed-relProven[denom])
		free := lock(denom) - reserved
		if d.Config.Kind == KindUnescrow && total > free {
			return nil, ufmt.Errorf("controls: %d of %s is above the free lock of %d", total, denom, free)
		}
	}
	return plan, nil
}

// ApplySettlement applies a settlement PlanSettlement checked, in the same
// transaction: it settles every record, books the losses, parks the refunds
// the plan parks, and returns the refunds to pay now (the plan's Payments).
func (rt *Route) ApplySettlement(plan *SettlePlan) []RefundPayment {
	client, incident := plan.client, plan.incident
	// First every settled send releases what it holds, its supply
	// reservation and its queued refund, before anything is added.
	was := map[uint64]bool{}
	for _, it := range plan.items {
		if it.Action == SettleForgedReceive {
			continue
		}
		r := rt.send(PacketKey(client, it.Seq))
		d := rt.Denom(r.Denom)
		was[it.Seq] = isOpen(r)
		rt.unmarkProcessed(r)
		if r.Payment == PayQueued {
			rt.unqueue(d, r)
			r.Payment = PayRejected
		}
		rt.release(d, r)
		d.Totals.ProvenOwed -= r.ProvenReserve
		r.ProvenReserve = 0
	}
	// Then the parked refunds are added.
	for _, it := range plan.items {
		if it.Action == SettlePay && it.Amount > 0 && plan.parked[it.Seq] {
			r := rt.send(PacketKey(client, it.Seq))
			r.Settlement = it.Action
			rt.park(rt.Denom(r.Denom), r, it.Amount)
		}
	}
	// Then the records, the losses and the refunds paid now.
	var out []RefundPayment
	for _, it := range plan.items {
		key := PacketKey(client, it.Seq)
		if it.Action == SettleForgedReceive {
			denom, _, _ := rt.forgedReceive(key)
			d := rt.Denom(denom)
			if c := rt.claim(key); c != nil {
				// The claim is forged: its unpaid remainder is dropped and
				// it leaves its queue, so nothing more of it is paid.
				rem := c.Remaining()
				switch c.State {
				case Open:
					d.Totals.Owed -= rem
					rt.dequeue(d, c, d.queues.Get(string(c.To)).(*queue))
				case Withheld:
					d.Totals.Withheld -= rem
				}
				c.State = Forged
			} else if e := rt.sweep(key); e != nil && !e.Paid {
				// A claim moved to the sweep queue: its live remainder is
				// dropped, so no decision pays it.
				d.Totals.Swept -= e.Amount
				e.Voided = true
			}
			rt.addLoss(d, Loss{Key: key, Direction: DirRecv, Denom: denom, Amount: it.Amount, Chain: ChainGno, Incident: incident, Cause: CauseForgedReceive})
			continue
		}
		r := rt.send(key)
		d := rt.Denom(r.Denom)
		switch it.Action {
		case SettlePay:
			if it.Amount > 0 && !plan.parked[it.Seq] {
				rt.refunded(d, r, it.Amount)
				r.Payment = PayReconciled
				out = append(out, RefundPayment{Key: key, Denom: r.Denom, To: r.Sender, Amount: it.Amount})
			}
		case SettleLoss:
			rt.addLoss(d, Loss{Key: key, Direction: DirSend, Denom: r.Denom, Amount: it.Amount, Chain: ChainGno, Incident: incident, Cause: CauseRefundForDelivered})
		}
		r.Settlement = it.Action
		r.Incident = incident
		rt.track(r, was[it.Seq])
	}
	return out
}

// park books a settled genuine refund of a minted denom that the outstanding
// supply cannot hold now (its integer capacity is spent): the record is
// settled, so it no longer blocks a reopening, and its refund is owed and
// queued (PayQueued, counted in QueuedRefunds), paid later by PayRefunds
// within the supply's headroom, the refund meter and any refunds hold, like
// every queued refund. The amount is reserved again (Reservation, counted in
// Parked, apart from the in-flight burns' Returning), so it counts against
// the supply cap: no credit admitted meanwhile takes the capacity it needs,
// and a voucher return is never refused for it.
func (rt *Route) park(d *Denom, r *SendRecord, amount int64) {
	d.queueRefund(r.Key, amount)
	r.Payment = PayQueued
	r.Reservation = amount
	d.Totals.Parked = mustAdd(d.Totals.Parked, amount) // checked by PlanSettlement
}

// forgedReceive is the denom and what the receive of key (an inbound
// sequence of a retired client) paid out: its claim's installments (fee
// included), or the sweep entry a decision paid. A receive whose forged void
// booked its loss already, or whose loss is booked, is refused: once.
func (rt *Route) forgedReceive(key string) (string, int64, error) {
	if rt.LossBooked(DirRecv, key) {
		return "", 0, errors.New("the loss of receive " + key + " is booked already")
	}
	if c := rt.claim(key); c != nil {
		if c.State == Forged {
			return "", 0, errors.New("receive " + key + " was voided as forged: its loss is booked")
		}
		if c.Paid == 0 {
			return "", 0, errors.New("receive " + key + " paid nothing out: void it instead")
		}
		return c.Denom, c.Paid, nil
	}
	if e := rt.sweep(key); e != nil && !e.Voided {
		if paid := e.paidOut(); paid > 0 {
			return e.Denom, paid, nil
		}
	}
	return "", 0, errors.New("no receive of " + key + " paid anything out")
}

// ProveOutcome stores the destination's outcome of the send of key, proven by
// the caller through the route's replacement client at height (ADR pr6375
// §7.12): packet must be the record's (its commitment), its client one a
// replacement retired, the record unsettled, and height not below an earlier
// proof's (a later state of the destination supersedes an earlier one, never
// the other way round). gen is verifier's trust generation: the outcome holds
// only while trusted(verifier, gen) (see SettleRecords).
func (rt *Route) ProveOutcome(key string, packet types.Packet, outcome uint8, height uint64, verifier string, gen uint64, trusted func(client string, gen uint64) bool) error {
	r := rt.send(key)
	if r == nil {
		return errors.New("controls: no send record for " + key)
	}
	if string(types.CommitPacket(packet)) != string(r.Commitment) || key != PacketKey(packet.SourceClient, packet.Sequence) {
		return errors.New("controls: the packet is not send " + key + "'s")
	}
	retired := false
	for _, c := range rt.Replaced {
		if c == packet.SourceClient {
			retired = true
		}
	}
	if !retired {
		return errors.New("controls: " + packet.SourceClient + " is no client a replacement retired from route " + rt.Key)
	}
	if r.Settlement != 0 {
		return errors.New("controls: send " + key + " is settled already")
	}
	if outcome < ProvenDelivered || outcome > ProvenCollision {
		return errors.New("controls: unknown outcome")
	}
	// A proven outcome is final (an acknowledgement, a receipt, an absence
	// past the timeout): it is proven again only once its verifier no longer
	// vouches for it (not Active, or a new trust generation), which voids it.
	if r.Proven != ProvenNone && trusted(r.ProvenBy, r.ProvenGen) {
		return ufmt.Errorf("controls: send %s's outcome is proven already", key)
	}
	// A refund proven owed on a send whose forged success released what it
	// held is reserved again at once, until its settlement: another
	// settlement, payout or credit in between never takes its backing (a
	// void proof's reservation is released, the new proof's taken).
	d := rt.Denom(r.Denom)
	owed := int64(0)
	if r.Outcome == OutcomeSuccess && (outcome == ProvenRefundable || outcome == ProvenCollision) {
		owed = r.Amount - r.Refunded
	}
	if _, ok := checkedAdd(d.Totals.ProvenOwed-r.ProvenReserve, owed); !ok {
		return errors.New("controls: the proven refunds of " + r.Denom + " would overflow")
	}
	d.Totals.ProvenOwed -= r.ProvenReserve
	d.Totals.ProvenOwed += owed
	r.ProvenReserve = owed
	r.Proven, r.ProvenAt, r.ProvenBy, r.ProvenGen = outcome, height, verifier, gen
	return nil
}

// unqueue takes a record's queued refund out of the queue, unpaid, found by
// its key in logarithmic work.
func (rt *Route) unqueue(d *Denom, r *SendRecord) {
	if v := d.refundIdx.Get(r.Key); v != nil {
		d.refundQueue.Remove(v.(string))
		d.refundIdx.Remove(r.Key)
	}
	d.Totals.QueuedRefunds -= r.Amount - r.Refunded
}
