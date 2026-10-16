package controls

import (
	"testing"

	"gno.land/p/aib/ibc/types/v0"
)

func sendRec(seq uint64, denom, kind string, amount int64) SendRecord {
	p := types.Packet{
		Sequence: seq, SourceClient: "ethereum-1", DestinationClient: "client-0", TimeoutTimestamp: 99,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/x-solidity-abi", Value: []byte{1, 2, 3}}},
	}
	return SendRecord{
		Key: pk(seq), Packet: p, Commitment: types.CommitPacket(p), Sender: alice, Receiver: "0xabc",
		Denom: denom, Kind: kind, Amount: amount, Fee: 20, SentHeight: 5, SentAt: t0,
	}
}

func TestRecordSendIsImmutableAndCopied(t *testing.T) {
	_, rt := newRoute(t)
	rec := sendRec(1, "ugnot", KindUnescrow, 1_000)
	if err := rt.RecordSend(rec); err != nil {
		t.Fatal(err)
	}
	// The caller's slices are not aliased.
	rec.Packet.Payloads[0].Value[0] = 9
	rec.Commitment[0] ^= 1
	got, ok := rt.Send(pk(1))
	if !ok || got.Packet.Payloads[0].Value[0] != 1 || string(got.Commitment) != string(types.CommitPacket(got.Packet)) {
		t.Fatalf("the record aliases its input: %+v", got)
	}
	// Nor is the copy handed out.
	got.Packet.Payloads[0].Value[0] = 7
	again, _ := rt.Send(pk(1))
	if again.Packet.Payloads[0].Value[0] != 1 {
		t.Fatalf("Send hands out an alias")
	}
	if err := rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 5)); err == nil {
		t.Fatalf("a record written twice")
	}
	if err := rt.RecordSend(sendRec(2, "ugnot", KindMint, 5)); err == nil {
		t.Fatalf("a record with the wrong accounting")
	}
	if err := rt.RecordSend(sendRec(2, "uatom", KindUnescrow, 5)); err == nil {
		t.Fatalf("a record of an unknown denom")
	}
	d := rt.Denom("ugnot")
	if d.Totals.Sent != 1_000 || d.Totals.SendFees != 20 {
		t.Fatalf("totals %+v", d.Totals)
	}
}

func TestSettleSuccessOwesNothing(t *testing.T) {
	_, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	pay, err := rt.Settle(t0+60, 77, pk(1), OutcomeSuccess, false)
	if err != nil || pay != 0 {
		t.Fatalf("%d %v", pay, err)
	}
	r, _ := rt.Send(pk(1))
	if r.Outcome != OutcomeSuccess || r.ProcessedHeight != 77 || r.ProcessedAt != t0+60 || r.Payment != PayNone {
		t.Fatalf("%+v", r)
	}
	if _, err := rt.Settle(t0+60, 78, pk(1), OutcomeTimeout, false); err == nil {
		t.Fatalf("settled twice")
	}
	if _, err := rt.Settle(t0+60, 78, pk(9), OutcomeTimeout, false); err == nil {
		t.Fatalf("settled a missing record")
	}
}

// A refund within the refund meter is paid at once; beyond it, it is queued
// and paid by PayRefunds as the meter refills (ADR pr6375 §7.13). The refund
// meter starts empty and is not replenished by refunds.
func TestRefundMeter(t *testing.T) {
	_, rt := newRoute(t) // refund cap 10000/day
	for i := uint64(1); i <= 4; i++ {
		rt.RecordSend(sendRec(i, "ugnot", KindUnescrow, 3_000))
	}
	// Half a day after enrolment the meter holds 5000: one refund at once.
	pay, _ := rt.Settle(t0+Day/2, 10, pk(1), OutcomeError, false)
	if pay != 3_000 {
		t.Fatalf("at once: %d", pay)
	}
	// 2000 left: the next is queued, and the one after it queues behind it.
	pay, _ = rt.Settle(t0+Day/2, 10, pk(2), OutcomeTimeout, false)
	if pay != 0 {
		t.Fatalf("over the meter paid %d", pay)
	}
	pay, _ = rt.Settle(t0+Day/2+3*3600, 11, pk(3), OutcomeTimeout, false)
	if pay != 0 {
		t.Fatalf("paid ahead of the queue: %d", pay)
	}
	d := rt.Denom("ugnot")
	if d.Totals.QueuedRefunds != 6_000 || rt.QueuedRefundCount("ugnot") != 2 || d.Totals.Refunded != 3_000 {
		t.Fatalf("totals %+v", d.Totals)
	}
	r2, _ := rt.Send(pk(2))
	if r2.Payment != PayQueued || r2.Outcome != OutcomeTimeout {
		t.Fatalf("%+v", r2)
	}
	// Three hours later the meter holds 2000 + 1250: the head refund is paid
	// in an installment of 3250 > 3000? It pays what it owes, 3000.
	ps, err := rt.PayRefunds(t0+Day/2+3*3600, "ugnot", 20, false)
	if err != nil || len(ps) != 1 || ps[0].Key != pk(2) || ps[0].Amount != 3_000 || ps[0].To != alice {
		t.Fatalf("%+v %v", ps, err)
	}
	r2, _ = rt.Send(pk(2))
	if r2.Payment != PayClaimed || r2.Refunded != 3_000 {
		t.Fatalf("%+v", r2)
	}
	// 250 left, below an hour of the cap (416): the next waits.
	ps, _ = rt.PayRefunds(t0+Day/2+3*3600, "ugnot", 20, false)
	if len(ps) != 0 {
		t.Fatalf("paid a sliver %+v", ps)
	}
	// An hour later 666: an installment.
	ps, _ = rt.PayRefunds(t0+Day/2+4*3600, "ugnot", 20, false)
	if len(ps) != 1 || ps[0].Amount != 666 {
		t.Fatalf("installment %+v", ps)
	}
	r3, _ := rt.Send(pk(3))
	if r3.Payment != PayQueued || r3.Refunded != 666 {
		t.Fatalf("%+v", r3)
	}
	// A refunds hold pays nothing and queues everything.
	pay, _ = rt.Settle(t0+5*Day, 12, pk(4), OutcomeError, true)
	if pay != 0 {
		t.Fatalf("paid under a hold")
	}
	ps, _ = rt.PayRefunds(t0+5*Day, "ugnot", 20, true)
	if len(ps) != 0 {
		t.Fatalf("paid under a hold")
	}
	// Lifted: the queue drains in order.
	ps, _ = rt.PayRefunds(t0+5*Day, "ugnot", 20, false)
	if len(ps) != 2 || ps[0].Key != pk(3) || ps[0].Amount != 3_000-666 || ps[1].Key != pk(4) || ps[1].Amount != 3_000 {
		t.Fatalf("%+v", ps)
	}
	if d.Totals.QueuedRefunds != 0 || d.Totals.Refunded != 12_000 || rt.QueuedRefundCount("ugnot") != 0 {
		t.Fatalf("totals %+v", d.Totals)
	}
}

// A refund larger than the refund cap is still paid, in installments.
func TestRefundLargerThanCap(t *testing.T) {
	_, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 25_000))
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, false)
	var paid int64
	for day := int64(1); day <= 3; day++ {
		ps, _ := rt.PayRefunds(t0+day*Day, "ugnot", 20, false)
		for _, p := range ps {
			paid += p.Amount
		}
	}
	if paid != 25_000 {
		t.Fatalf("paid %d", paid)
	}
}

// A burned voucher's refund mints it again: outstanding vouchers come back.
func TestMintRefundRestoresOutstanding(t *testing.T) {
	_, rt := newRoute(t)
	d := rt.Denom("ibc/WETH")
	d.Totals.Outstanding = 5_000
	rt.RecordSend(sendRec(1, "ibc/WETH", KindMint, 2_000))
	if d.Totals.Outstanding != 3_000 {
		t.Fatalf("burn: %d", d.Totals.Outstanding)
	}
	pay, _ := rt.Settle(t0+Day, 1, pk(1), OutcomeError, false)
	if pay != 2_000 || d.Totals.Outstanding != 5_000 {
		t.Fatalf("refund %d outstanding %d", pay, d.Totals.Outstanding)
	}
}

func TestRejectRefundAndPayEntitlement(t *testing.T) {
	_, rt := newRoute(t)
	for i := uint64(1); i <= 3; i++ {
		rt.RecordSend(sendRec(i, "ugnot", KindUnescrow, 3_000))
	}
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, false) // queued (empty meter)
	rt.Settle(t0, 1, pk(2), OutcomeTimeout, false) // queued
	rt.Settle(t0, 1, pk(3), OutcomeSuccess, false)
	d := rt.Denom("ugnot")
	// The reconciliation finds packet 1 delivered: its queued refund is rejected.
	if err := rt.RejectRefund(pk(1), "inc-1"); err != nil {
		t.Fatal(err)
	}
	if err := rt.RejectRefund(pk(1), "inc-1"); err == nil {
		t.Fatalf("rejected twice")
	}
	if err := rt.RejectRefund(pk(3), "inc-1"); err == nil {
		t.Fatalf("rejected a success")
	}
	if d.Totals.QueuedRefunds != 3_000 || rt.QueuedRefundCount("ugnot") != 1 {
		t.Fatalf("totals %+v", d.Totals)
	}
	if _, err := rt.PayEntitlement(pk(1), 1, "inc-1"); err == nil {
		t.Fatalf("paid a rejected refund")
	}
	// Packet 3's success ack was forged: the reconciliation pays it by decision.
	p, err := rt.PayEntitlement(pk(3), 3_000, "inc-1")
	if err != nil || p.Amount != 3_000 || p.To != alice {
		t.Fatalf("%+v %v", p, err)
	}
	if _, err := rt.PayEntitlement(pk(3), 1, "inc-1"); err == nil {
		t.Fatalf("paid more than owed")
	}
	// Packet 2's queued refund, paid by decision, leaves the queue.
	if _, err := rt.PayEntitlement(pk(2), 3_000, "inc-1"); err != nil {
		t.Fatal(err)
	}
	r2, _ := rt.Send(pk(2))
	if r2.Payment != PayReconciled || rt.QueuedRefundCount("ugnot") != 0 || d.Totals.QueuedRefunds != 0 {
		t.Fatalf("%+v %+v", r2, d.Totals)
	}
	ps, _ := rt.PayRefunds(t0+5*Day, "ugnot", 20, false)
	if len(ps) != 0 {
		t.Fatalf("paid a settled refund again: %+v", ps)
	}
}
