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
	PayQueued     = "queued"     // refund owed, waiting under the refund meter or a refunds hold
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
	SentHeight int64 // 0 for a backfilled send
	SentAt     int64
	Backfilled bool // a send from before the controls, recorded from the core's commitment

	Outcome         string
	ProcessedHeight int64
	ProcessedAt     int64
	Payment         string
	Refunded        int64 // what was refunded so far, at once, by claims or by decision
	Settlement      uint8 // the reconciliation's action (SettlePay...), 0 while unsettled
	Reservation     int64 // KindMint: the supply this send still holds against the cap, released or consumed once
	Proven          uint8 // the destination's outcome, proven through the replacement client (ProvenDelivered...)
	ProvenAt        uint64 // the proof's height on the replacement client
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

// Backfill records a send made before the route's controls (by impl/v0)
// that is still outstanding: the caller authenticated rec.Packet against the
// core's stored commitment, which is present until the send's
// acknowledgement or timeout is processed (ADR pr6375 §7.13: every send on
// an Ethereum route has a record before relaying resumes). Its escrow or
// burn happened before the controls: an unescrowed denom's escrow already
// holds it, a minted denom's outstanding supply (counted when the denom was
// enabled) already excludes it. A minted send reserves its supply until it
// settles, as any return does. Its refund then goes through the refund meter
// and the refunds hold like every other.
func (rt *Route) Backfill(rec SendRecord) error {
	if _, _, ok := ParsePacketKey(rec.Key); !ok {
		return errors.New("controls: not a packet key: " + rec.Key)
	}
	if rt.sends.Has(rec.Key) {
		return errors.New("controls: a send record exists for " + rec.Key)
	}
	d := rt.Denom(rec.Denom)
	if d == nil {
		return errors.New("controls: denom " + rec.Denom + " is not enabled on route " + rt.Key + ": enable it before backfilling its sends")
	}
	if rec.Kind != d.Config.Kind {
		return errors.New("controls: the send's accounting differs from its denom's")
	}
	if rec.Amount <= 0 || rec.Fee != 0 {
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
	r.Backfilled = true
	r.Outcome, r.ProcessedHeight, r.ProcessedAt, r.Payment, r.Refunded, r.Settlement, r.Incident = OutcomePending, 0, 0, PayNone, 0, 0, ""
	r.Reservation = 0
	rt.sends.Set(r.Key, &r)
	rt.track(&r, false)
	rt.addPending(r.Key, 1)
	if rt.Unimported > 0 {
		rt.Unimported--
	}
	d.Totals.Sent = statAdd(d.Totals.Sent, r.Amount)
	if d.Config.Kind == KindMint {
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
		return
	}
	rt.openSends.Set(client, n)
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
	covered := d.Config.Kind == KindMint || lock >= owed
	d.refundMeter.Refill(now, d.Config.RefundCap, d.Config.RefundCap, 0, 0)
	if !hold && covered && d.refundQueue.Size() == 0 && d.refundMeter.Level >= owed {
		d.refundMeter.Take(owed)
		rt.refunded(d, r, owed)
		r.Payment = PayPaid
		return owed, nil
	}
	d.refundSeq++
	d.refundQueue.Set(seqKey(d.refundSeq), key)
	d.Totals.QueuedRefunds = mustAdd(d.Totals.QueuedRefunds, owed) // at most InFlight
	r.Payment = PayQueued
	return 0, nil
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
		d.Totals.Returning -= consumed
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
		d.refundMeter.Take(pay)
		rt.refunded(d, r, pay)
		d.Totals.QueuedRefunds -= pay
		if r.Refunded == r.Amount {
			d.refundQueue.Remove(k)
			r.Payment = PayClaimed
			rt.track(r, true)
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
	SettlePay       = uint8(1) // a genuine refund: pay its whole remainder, Amount = what the packet carried minus what was refunded (0 if paid in full)
	SettleReject    = uint8(2) // reject a queued refund, none of it paid: the packet was delivered
	SettleDelivered = uint8(3) // the packet was delivered, no refund paid: settled, nothing owed (a queued refund is rejected)
	SettleLoss      = uint8(4) // a forged refund: the unpaid remainder rejected, what was paid (Amount) recorded as a loss
	SettleForgedReceive = uint8(5) // a forged receive: Seq is an inbound sequence; what its receive paid out (Amount) is a loss, once
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
// before anything changes. It returns the refunds to pay.
func (rt *Route) SettleRecords(client string, items []SettleItem, incident string, lock func(denom string) int64) ([]RefundPayment, error) {
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
	queued := map[string]int64{} // the queued remainders the payments settle: their own reserve
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
		// The action must match the outcome proven through the replacement
		// client (ADR pr6375 §7.12): governance chooses, the proof decides.
		switch {
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
			if r.Payment == PayQueued {
				if queued[r.Denom], ok = checkedAdd(queued[r.Denom], r.Amount-r.Refunded); !ok {
					return nil, ufmt.Errorf("controls: item %d: the settlement's queued refunds overflow", i)
				}
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
			if rt.losses.Has(lossKey(key, CauseRefundForDelivered)) {
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
	for denom, total := range pays {
		d := rt.Denom(denom)
		// A minted refund paid beyond what its send still reserves mints
		// vouchers anew: the outstanding supply must hold them.
		if _, ok := checkedAdd(d.Totals.Outstanding, total); d.Config.Kind == KindMint && !ok {
			return nil, errors.New("controls: the settlement's refunds would overflow the outstanding supply of " + denom)
		}
		free := lock(denom) - d.Reserved() + queued[denom]
		if d.Config.Kind == KindUnescrow && total > free {
			return nil, ufmt.Errorf("controls: %d of %s is above the free lock of %d", total, denom, free)
		}
	}
	var out []RefundPayment
	for _, it := range items {
		key := PacketKey(client, it.Seq)
		if it.Action == SettleForgedReceive {
			denom, _, _ := rt.forgedReceive(key)
			rt.addLoss(rt.Denom(denom), Loss{Key: key, Denom: denom, Amount: it.Amount, Chain: ChainGno, Incident: incident, Cause: CauseForgedReceive})
			continue
		}
		r := rt.send(key)
		d := rt.Denom(r.Denom)
		was := isOpen(r)
		rt.unmarkProcessed(r)
		if r.Payment == PayQueued {
			rt.unqueue(d, r)
			r.Payment = PayRejected
		}
		switch it.Action {
		case SettlePay:
			if it.Amount > 0 {
				rt.refunded(d, r, it.Amount)
				r.Payment = PayReconciled
				out = append(out, RefundPayment{Key: key, Denom: r.Denom, To: r.Sender, Amount: it.Amount})
			}
		case SettleLoss:
			rt.addLoss(d, Loss{Key: key, Denom: r.Denom, Amount: it.Amount, Chain: ChainGno, Incident: incident, Cause: CauseRefundForDelivered})
		}
		rt.release(d, r)
		r.Settlement = it.Action
		r.Incident = incident
		rt.track(r, was)
	}
	return out, nil
}

// forgedReceive is the denom and what the receive of key (an inbound
// sequence of a retired client) paid out: its claim's installments (fee
// included), or the sweep entry a decision paid. A receive whose forged void
// booked its loss already, or whose loss is booked, is refused: once.
func (rt *Route) forgedReceive(key string) (string, int64, error) {
	if rt.losses.Has(lossKey(key, CauseForgedReceive)) {
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
	if e := rt.sweep(key); e != nil && e.Paid && e.PaidTo != "credit by vote" && !e.Voided {
		return e.Denom, e.Amount, nil
	}
	return "", 0, errors.New("no receive of " + key + " paid anything out")
}

// ProveOutcome stores the destination's outcome of the send of key, proven by
// the caller through the route's replacement client at height (ADR pr6375
// §7.12): packet must be the record's (its commitment), its client one a
// replacement retired, the record unsettled, and height not below an earlier
// proof's (a later state of the destination supersedes an earlier one, never
// the other way round).
func (rt *Route) ProveOutcome(key string, packet types.Packet, outcome uint8, height uint64) error {
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
	if height < r.ProvenAt {
		return ufmt.Errorf("controls: send %s's outcome was proven at height %d already", key, r.ProvenAt)
	}
	r.Proven, r.ProvenAt = outcome, height
	return nil
}

// unqueue takes a record's queued refund out of the queue, unpaid.
func (rt *Route) unqueue(d *Denom, r *SendRecord) {
	d.refundQueue.Iterate("", "", func(k string, v any) bool {
		if v.(string) == r.Key {
			d.refundQueue.Remove(k)
			return true
		}
		return false
	})
	d.Totals.QueuedRefunds -= r.Amount - r.Refunded
}
