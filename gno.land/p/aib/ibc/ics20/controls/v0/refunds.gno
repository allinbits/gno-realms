package controls

import (
	"errors"

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
	PayRejected   = "rejected"   // a queued refund a reconciliation rejected (the packet was delivered)
	PayReconciled = "reconciled" // an entitlement a reconciliation paid by decision
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
	Refunded        int64 // what was refunded so far, at once, by claims or by decision
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
	r := rec
	r.Packet = copyPacket(rec.Packet)
	r.Commitment = append([]byte{}, rec.Commitment...)
	r.Outcome, r.ProcessedHeight, r.ProcessedAt, r.Payment, r.Refunded, r.Incident = OutcomePending, 0, 0, PayNone, 0, ""
	rt.sends.Set(r.Key, &r)
	d.Totals.Sent += r.Amount
	d.Totals.SendFees += r.Fee
	if d.Config.Kind == KindMint {
		d.Totals.Outstanding -= r.Amount
		if d.Totals.Outstanding < 0 {
			// vouchers minted before the route was controlled
			d.Totals.Outstanding = 0
		}
	}
	return nil
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
// timeout owes a refund of the amount (the fee is not refunded): paid at once
// when no refunds hold stands, no refund of the denom is queued ahead and the
// refund meter holds the amount (the meter then pays it); queued otherwise,
// to be paid by ClaimRefunds as the meter refills. It returns what to refund
// now (0 when queued). A record is settled once.
func (rt *Route) Settle(now, height int64, key, outcome string, hold bool) (int64, error) {
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
	r.Outcome, r.ProcessedHeight, r.ProcessedAt = outcome, height, now
	if outcome == OutcomeSuccess {
		return 0, nil
	}
	d.refundMeter.Refill(now, d.Config.RefundCap, d.Config.RefundCap, 0, 0)
	if !hold && d.refundQueue.Size() == 0 && d.refundMeter.Level >= r.Amount {
		d.refundMeter.Take(r.Amount)
		rt.refunded(d, r, r.Amount)
		r.Payment = PayPaid
		return r.Amount, nil
	}
	d.refundSeq++
	d.refundQueue.Set(seqKey(d.refundSeq), key)
	d.Totals.QueuedRefunds += r.Amount
	r.Payment = PayQueued
	return 0, nil
}

// refunded books amount refunded on r.
func (rt *Route) refunded(d *Denom, r *SendRecord, amount int64) {
	r.Refunded += amount
	d.Totals.Refunded += amount
	if d.Config.Kind == KindMint {
		d.Totals.Outstanding += amount // the burned vouchers are minted again
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
// queue stops at the first refund the meter cannot serve. A refunds hold pays
// nothing. It books the payments and returns them.
func (rt *Route) PayRefunds(now int64, denom string, n int, hold bool) ([]RefundPayment, error) {
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
		d.refundMeter.Take(pay)
		rt.refunded(d, r, pay)
		d.Totals.QueuedRefunds -= pay
		if r.Refunded == r.Amount {
			d.refundQueue.Remove(k)
			r.Payment = PayClaimed
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

// RejectRefund rejects a queued refund that a reconciliation found was for a
// delivered packet (ADR pr6375 §7.12): it leaves the queue unpaid, what it
// already paid stays booked as refunded (a loss the reconciliation records
// separately).
func (rt *Route) RejectRefund(key, incident string) error {
	r := rt.send(key)
	if r == nil {
		return errors.New("controls: no send record for " + key)
	}
	if r.Payment != PayQueued {
		return errors.New("controls: send " + key + " has no queued refund")
	}
	d := rt.Denom(r.Denom)
	d.refundQueue.Iterate("", "", func(k string, v any) bool {
		if v.(string) == key {
			d.refundQueue.Remove(k)
			return true
		}
		return false
	})
	d.Totals.QueuedRefunds -= r.Amount - r.Refunded
	r.Payment = PayRejected
	r.Incident = incident
	return nil
}

// PayEntitlement pays by decision what a reconciliation found a sender is
// owed on a send (ADR pr6375 §7.12): the packet's amount minus what was
// already refunded, never more. A queued refund it settles leaves the queue.
// It returns the payment to make.
func (rt *Route) PayEntitlement(key string, amount int64, incident string) (RefundPayment, error) {
	r := rt.send(key)
	if r == nil {
		return RefundPayment{}, errors.New("controls: no send record for " + key)
	}
	if r.Payment == PayRejected {
		return RefundPayment{}, errors.New("controls: send " + key + "'s refund was rejected")
	}
	rem := r.Amount - r.Refunded
	if amount <= 0 || amount > rem {
		return RefundPayment{}, ufmt.Errorf("controls: %d is not within what send %s is still owed (%d)", amount, key, rem)
	}
	d := rt.Denom(r.Denom)
	if r.Payment == PayQueued {
		d.Totals.QueuedRefunds -= amount
		if amount == rem {
			d.refundQueue.Iterate("", "", func(k string, v any) bool {
				if v.(string) == key {
					d.refundQueue.Remove(k)
					return true
				}
				return false
			})
		}
	}
	rt.refunded(d, r, amount)
	if r.Refunded == r.Amount || r.Payment != PayQueued {
		r.Payment = PayReconciled
	}
	r.Incident = incident
	return RefundPayment{Key: key, Denom: r.Denom, To: r.Sender, Amount: amount}, nil
}
