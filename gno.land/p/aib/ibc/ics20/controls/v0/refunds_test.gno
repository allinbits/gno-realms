package controls

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/aib/ibc/types/v0"
)

// big is a lock that covers every refund.
const big = int64(1_000_000_000)

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
	pay, err := rt.Settle(t0+60, 77, pk(1), OutcomeSuccess, false, big)
	if err != nil || pay != 0 {
		t.Fatalf("%d %v", pay, err)
	}
	r, _ := rt.Send(pk(1))
	if r.Outcome != OutcomeSuccess || r.ProcessedHeight != 77 || r.ProcessedAt != t0+60 || r.Payment != PayNone {
		t.Fatalf("%+v", r)
	}
	if _, err := rt.Settle(t0+60, 78, pk(1), OutcomeTimeout, false, big); err == nil {
		t.Fatalf("settled twice")
	}
	if _, err := rt.Settle(t0+60, 78, pk(9), OutcomeTimeout, false, big); err == nil {
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
	pay, _ := rt.Settle(t0+Day/2, 10, pk(1), OutcomeError, false, big)
	if pay != 3_000 {
		t.Fatalf("at once: %d", pay)
	}
	// 2000 left: the next is queued, and the one after it queues behind it.
	pay, _ = rt.Settle(t0+Day/2, 10, pk(2), OutcomeTimeout, false, big)
	if pay != 0 {
		t.Fatalf("over the meter paid %d", pay)
	}
	pay, _ = rt.Settle(t0+Day/2+3*3600, 11, pk(3), OutcomeTimeout, false, big)
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
	ps, err := rt.PayRefunds(t0+Day/2+3*3600, "ugnot", 20, false, big)
	if err != nil || len(ps) != 1 || ps[0].Key != pk(2) || ps[0].Amount != 3_000 || ps[0].To != alice {
		t.Fatalf("%+v %v", ps, err)
	}
	r2, _ = rt.Send(pk(2))
	if r2.Payment != PayClaimed || r2.Refunded != 3_000 {
		t.Fatalf("%+v", r2)
	}
	// 250 left, below an hour of the cap (416): the next waits.
	ps, _ = rt.PayRefunds(t0+Day/2+3*3600, "ugnot", 20, false, big)
	if len(ps) != 0 {
		t.Fatalf("paid a sliver %+v", ps)
	}
	// An hour later 666: an installment.
	ps, _ = rt.PayRefunds(t0+Day/2+4*3600, "ugnot", 20, false, big)
	if len(ps) != 1 || ps[0].Amount != 666 {
		t.Fatalf("installment %+v", ps)
	}
	r3, _ := rt.Send(pk(3))
	if r3.Payment != PayQueued || r3.Refunded != 666 {
		t.Fatalf("%+v", r3)
	}
	// A refunds hold pays nothing and queues everything.
	pay, _ = rt.Settle(t0+5*Day, 12, pk(4), OutcomeError, true, big)
	if pay != 0 {
		t.Fatalf("paid under a hold")
	}
	ps, _ = rt.PayRefunds(t0+5*Day, "ugnot", 20, true, big)
	if len(ps) != 0 {
		t.Fatalf("paid under a hold")
	}
	// Lifted: the queue drains in order.
	ps, _ = rt.PayRefunds(t0+5*Day, "ugnot", 20, false, big)
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
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, false, big)
	var paid int64
	for day := int64(1); day <= 3; day++ {
		ps, _ := rt.PayRefunds(t0+day*Day, "ugnot", 20, false, big)
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
	pay, _ := rt.Settle(t0+Day, 1, pk(1), OutcomeError, false, big)
	if pay != 2_000 || d.Totals.Outstanding != 5_000 {
		t.Fatalf("refund %d outstanding %d", pay, d.Totals.Outstanding)
	}
}

func lockOf(l int64) func(string) int64 { return func(string) int64 { return l } }

// A reconciliation settles the sends of a retired client once each: it pays
// a refund's whole remainder, rejects, marks delivered or settles a forged
// refund, and a queued refund leaves the queue under any action (Codex
// review #13, ADR pr6375 §5.4 kind 12).
func TestSettleRecords(t *testing.T) {
	r, rt := newRoute(t)
	for i := uint64(1); i <= 6; i++ {
		rt.RecordSend(sendRec(i, "ugnot", KindUnescrow, 3_000))
	}
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, false, big) // queued (empty meter)
	rt.Settle(t0, 1, pk(2), OutcomeTimeout, false, big) // queued
	rt.Settle(t0, 1, pk(3), OutcomeSuccess, false, big)
	// pk(6) was partly refunded from the queue, then the rest stays queued.
	rt.Settle(t0, 1, pk(6), OutcomeTimeout, false, big)
	rt.PayRefunds(t0+Day/4, "ugnot", 1, false, big) // pays pk(1) only partly
	r1, _ := rt.Send(pk(1))
	if r1.Refunded == 0 || r1.Refunded == r1.Amount {
		t.Fatalf("setup: %+v", r1)
	}
	// pk(4) and pk(5) never got an outcome: the client is retired.
	d := rt.Denom("ugnot")
	items := []SettleItem{{Seq: 1, Action: SettleLoss, Amount: r1.Refunded}, {Seq: 2, Action: SettlePay, Amount: 3_000},
		{Seq: 3, Action: SettleDelivered}, {Seq: 4, Action: SettleDelivered}, {Seq: 5, Action: SettlePay, Amount: 3_000},
		{Seq: 6, Action: SettleReject}}
	if _, err := settleProven(rt, "ethereum-1", items, "inc-1", lockOf(big)); err == nil {
		t.Fatalf("settled the sends of a live client")
	}
	if err := r.Replace("ethereum-1", "ethereum-2", 0, 1000); err != nil {
		t.Fatal(err)
	}
	before := d.Totals
	bad := [][]SettleItem{
		{{Seq: 3, Action: SettleReject}},                                                         // no queued refund
		{{Seq: 2, Action: SettlePay, Amount: 1_000}},                                             // cut short
		{{Seq: 2, Action: SettlePay, Amount: 3_001}},                                             // more than owed
		{{Seq: 1, Action: SettleLoss, Amount: 1}},                                                // not what was paid
		{{Seq: 2, Action: SettleLoss, Amount: 0}},                                                // nothing was paid
		{{Seq: 1, Action: SettleDelivered, Amount: 1}},                                           // an amount
		{{Seq: 1, Action: 5}},                                                                    // unknown
		{{Seq: 9, Action: SettleDelivered}},                                                      // no record
		{{Seq: 3, Action: SettleDelivered}, {Seq: 3, Action: SettleDelivered}},                   // twice
		{{Seq: 4, Action: SettlePay, Amount: 3_000}, {Seq: 5, Action: SettlePay, Amount: 3_000}}, // above the free lock below
	}
	for i, b := range bad {
		if _, err := settleProven(rt, "ethereum-1", b, "inc-1", lockOf(5_000+d.Reserved())); err == nil {
			t.Fatalf("bad settlement %d applied", i)
		}
	}
	if _, err := settleProven(rt, "ethereum-1", items, "", lockOf(big)); err == nil {
		t.Fatalf("settled without an incident")
	}
	if d.Totals != before {
		t.Fatalf("a refused settlement changed state")
	}
	refundedBefore := d.Totals.Refunded
	ps, err := settleProven(rt, "ethereum-1", items, "inc-1", lockOf(big))
	if err != nil {
		t.Fatal(err)
	}
	if len(ps) != 2 || ps[0].Amount+ps[1].Amount != 6_000 || ps[0].To != alice {
		t.Fatalf("%+v", ps)
	}
	if rt.QueuedRefundCount("ugnot") != 0 || d.Totals.QueuedRefunds != 0 || d.Totals.Lost != r1.Refunded || d.Totals.Refunded != refundedBefore+6_000 {
		t.Fatalf("%+v", d.Totals)
	}
	r1, _ = rt.Send(pk(1))
	r4, _ := rt.Send(pk(4))
	if r1.Payment != PayRejected || r1.Settlement != SettleLoss || r4.Settlement != SettleDelivered || rt.OpenSends("ethereum-1") != 0 {
		t.Fatalf("%+v %+v %d", r1, r4, rt.OpenSends("ethereum-1"))
	}
	// Exactly once: no item settles again, and no later outcome pays.
	for seq := uint64(1); seq <= 6; seq++ {
		if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: seq, Action: SettleDelivered}}, "inc-1", lockOf(big)); err == nil {
			t.Fatalf("settled %d twice", seq)
		}
	}
	if pay, err := rt.Settle(t0+Day, 2, pk(4), OutcomeTimeout, false, big); err != nil || pay != 0 {
		t.Fatalf("a settled send refunded again: %d %v", pay, err)
	}
	if ps, _ := rt.PayRefunds(t0+5*Day, "ugnot", 20, false, big); len(ps) != 0 {
		t.Fatalf("paid a settled refund: %+v", ps)
	}
}

// A minted send settled as delivered releases its supply reservation.
func TestSettleReleasesSupply(t *testing.T) {
	r, rt := newRoute(t)
	d := rt.Denom("ibc/WETH")
	d.Totals.Outstanding = 1_000
	rt.RecordSend(sendRec(1, "ibc/WETH", KindMint, 400))
	rt.RecordSend(sendRec(2, "ibc/WETH", KindMint, 300))
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	ps, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}, {Seq: 2, Action: SettlePay, Amount: 300}}, "inc", lockOf(0))
	if err != nil || len(ps) != 1 {
		t.Fatalf("%+v %v", ps, err)
	}
	if d.Totals.Returning != 0 || d.Totals.Outstanding != 600 {
		t.Fatalf("%+v", d.Totals)
	}
}

// A refund the escrow cannot cover is queued, not paid (an acknowledgement
// never fails on a short escrow); the queue pays it once the escrow allows.
func TestRefundQueuedWhenEscrowShort(t *testing.T) {
	_, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 3_000))
	pay, _ := rt.Settle(t0+Day, 1, pk(1), OutcomeTimeout, false, 2_000)
	if pay != 0 || rt.QueuedRefundCount("ugnot") != 1 {
		t.Fatalf("paid %d from an escrow of 2000", pay)
	}
	ps, _ := rt.PayRefunds(t0+Day, "ugnot", 20, false, 100)
	if len(ps) != 0 {
		t.Fatalf("paid a sliver of the escrow: %+v", ps)
	}
	ps, _ = rt.PayRefunds(t0+Day, "ugnot", 20, false, 2_000)
	if len(ps) != 1 || ps[0].Amount != 2_000 {
		t.Fatalf("%+v", ps)
	}
	ps, _ = rt.PayRefunds(t0+Day, "ugnot", 20, false, 5_000)
	if len(ps) != 1 || ps[0].Amount != 1_000 {
		t.Fatalf("%+v", ps)
	}
}

// A voucher return keeps its supply reserved until it settles: a receive
// cannot take the burned supply while the refund may still mint it again,
// queued under a hold or not (Codex review #7).
func TestPendingReturnReservesSupply(t *testing.T) {
	reg, rt := newRoute(t)
	d := rt.Denom("ibc/WETH")
	supplyCap := d.Config.SupplyCap
	d.Totals.Outstanding = supplyCap
	rt.RecordSend(sendRec(1, "ibc/WETH", KindMint, supplyCap))
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("a receive took the supply of a return in flight")
	}
	// The error ack's refund is queued under a hold: still reserved.
	if pay, _ := rt.Settle(t0+Day, 1, pk(1), OutcomeError, true, 0); pay != 0 {
		t.Fatalf("paid under a hold")
	}
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("a receive took the supply of a queued refund")
	}
	// Paid: the vouchers circulate again, the supply is full.
	for day := int64(2); day < 40 && rt.QueuedRefundCount("ibc/WETH") > 0; day++ {
		rt.PayRefunds(t0+day*Day, "ibc/WETH", 20, false, 0)
	}
	if d.Totals.Outstanding != supplyCap || d.Totals.Returning != 0 {
		t.Fatalf("%+v", d.Totals)
	}
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("over the cap")
	}
	// A return that succeeds frees its supply.
	rt.RecordSend(sendRec(2, "ibc/WETH", KindMint, 400))
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("freed before the ack")
	}
	rt.Settle(t0+50*Day, 1, pk(2), OutcomeSuccess, false, 0)
	if err := rt.CheckCredit("ibc/WETH", 400); err != nil {
		t.Fatal(err)
	}
	// A rejected refund frees what it did not refund.
	rt.RecordSend(sendRec(3, "ibc/WETH", KindMint, 300))
	rt.Settle(t0+50*Day, 1, pk(3), OutcomeTimeout, true, 0)
	reg.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 3, Action: SettleReject}}, "inc", lockOf(0)); err != nil {
		t.Fatal(err)
	}
	if err := rt.CheckCredit("ibc/WETH", 700); err != nil || d.Totals.Returning != 0 {
		t.Fatalf("%v %+v", err, d.Totals)
	}
}

// A send's supply reservation is released or consumed exactly once: a
// success releases it, and a later reconciliation of the same send (as
// delivered, or paying a refund after a forged success) releases nothing
// more, so the supply cap still holds (Codex round 2 #1).
func TestReservationReleasedOnce(t *testing.T) {
	r, rt := newRoute(t)
	d := rt.Denom("ibc/WETH")
	supplyCap := d.Config.SupplyCap
	d.Totals.Outstanding = supplyCap
	rt.RecordSend(sendRec(1, "ibc/WETH", KindMint, 400))
	rt.RecordSend(sendRec(2, "ibc/WETH", KindMint, 300))
	rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0)
	rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, 0)
	// The freed supply is taken by credits.
	mustCredit(t, rt, t0, 10, "ibc/WETH", alice, 700, 0)
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("over the cap")
	}
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	// Send 1 delivered; send 2's success was forged: its refund is paid.
	ps, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}, {Seq: 2, Action: SettlePay, Amount: 300}}, "inc", lockOf(0))
	if err != nil || len(ps) != 1 {
		t.Fatalf("%+v %v", ps, err)
	}
	if d.Totals.Returning != 0 {
		t.Fatalf("released twice: returning %d", d.Totals.Returning)
	}
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("a reconciliation freed supply that was taken: %+v", d.Totals)
	}
	r1, _ := rt.Send(pk(1))
	if r1.Reservation != 0 {
		t.Fatalf("%+v", r1)
	}
}

// A genuine refund paid in full during the suspect interval settles with a
// zero payment, once; a delivered settlement or a rejection is refused once
// a refund was paid (it is a forged refund: action 4) (Codex round 3 #5).
func TestSettleRefundPaidInFull(t *testing.T) {
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0+Day, 1, pk(1), OutcomeTimeout, false, big) // paid at once
	rt.Settle(t0+Day, 1, pk(2), OutcomeTimeout, false, big) // paid at once
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	for _, bad := range []SettleItem{{Seq: 1, Action: SettlePay, Amount: 1}, {Seq: 1, Action: SettleDelivered}} {
		if _, err := settleProven(rt, "ethereum-1", []SettleItem{bad}, "inc", lockOf(big)); err == nil {
			t.Fatalf("applied %+v", bad)
		}
	}
	ps, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay}}, "inc", lockOf(big))
	if err != nil || len(ps) != 0 {
		t.Fatalf("%+v %v", ps, err)
	}
	r1, _ := rt.Send(pk(1))
	if r1.Settlement != SettlePay || r1.Refunded != 1_000 || rt.OpenSends("ethereum-1") != 0 {
		t.Fatalf("%+v", r1)
	}
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay}}, "inc", lockOf(big)); err == nil {
		t.Fatalf("settled twice")
	}
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 2, Action: SettleLoss, Amount: 1_000}}, "inc", lockOf(big)); err != nil {
		t.Fatal(err)
	}
}

// A replacement names the height its suspect interval starts at: every send
// of the old client processed at or after it must be settled before the
// route reopens, counted in logarithmic work; one processed before it is not
// (ADR pr6375 §7.12).
func TestSuspectIntervalBlocksReopen(t *testing.T) {
	r, rt := newRoute(t)
	for i := uint64(1); i <= 4; i++ {
		rt.RecordSend(sendRec(i, "ugnot", KindUnescrow, 1_000))
	}
	rt.Settle(t0, 10, pk(1), OutcomeSuccess, false, big)
	rt.Settle(t0, 20, pk(2), OutcomeSuccess, false, big)
	rt.Settle(t0, 30, pk(3), OutcomeSuccess, false, big)
	rt.Settle(t0, 30, pk(4), OutcomeSuccess, false, big)
	if err := r.Replace("ethereum-1", "ethereum-2", -1, 1000); err == nil {
		t.Fatalf("a negative suspect height")
	}
	if err := r.Replace("ethereum-1", "ethereum-2", 20, 1000); err != nil {
		t.Fatal(err)
	}
	if n := rt.SuspectUnsettled("ethereum-1"); n != 3 {
		t.Fatalf("suspect %d", n)
	}
	if _, _, err := rt.Reopen(); err == nil || !strings.Contains(err.Error(), "suspect interval") {
		t.Fatalf("reopened with suspect records unsettled: %v", err)
	}
	settleProven(rt, "ethereum-1", []SettleItem{{Seq: 2, Action: SettleDelivered}, {Seq: 3, Action: SettleDelivered}}, "inc", lockOf(big))
	if n := rt.SuspectUnsettled("ethereum-1"); n != 1 {
		t.Fatalf("suspect %d", n)
	}
	settleProven(rt, "ethereum-1", []SettleItem{{Seq: 4, Action: SettleDelivered}}, "inc", lockOf(big))
	if _, _, err := rt.Reopen(); err != nil {
		t.Fatal(err)
	}
}

// Every aggregate a check reads stays exact or refuses: individually valid
// amounts never drive one past 2^63 (Codex round 4 #1, class A).
func TestAggregatesNeverWrap(t *testing.T) {
	const q = int64(1) << 62
	// Open sends (and so every refund they may owe, queued or not): the send
	// that would overflow them is refused.
	_, rt := newRoute(t)
	d := rt.Denom("ugnot")
	for i, want := range []bool{true, false, true} {
		amount := q
		if i == 2 {
			amount = q - 1
		}
		rec := sendRec(uint64(i+1), "ugnot", KindUnescrow, amount)
		if err := rt.RecordSend(rec); (err == nil) != want {
			t.Fatalf("send %d of %d: %v", i+1, amount, err)
		}
	}
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, 0)
	rt.Settle(t0, 1, pk(3), OutcomeTimeout, true, 0)
	if d.Totals.QueuedRefunds != q+(q-1) || d.Totals.InFlight != q+(q-1) {
		t.Fatalf("queued %d in flight %d", d.Totals.QueuedRefunds, d.Totals.InFlight)
	}
	// Claims and sweep entries: the credit that would overflow is refused.
	if _, err := rt.Credit(t0, 10, 0, pk(10), "ugnot", alice, q, ByPacket, "bridge realm", 0); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.Credit(t0, 10, 0, pk(11), "ugnot", alice, q, ByPacket, "bridge realm", 0); err == nil {
		t.Fatalf("liabilities wrapped")
	}
	if err := rt.CreditPending(t0, 10, 0, pk(12), "ugnot", alice, q, q, maxInt64); err == nil {
		t.Fatalf("liabilities wrapped by a pending credit")
	}
	// The reservation of claims and refunds together saturates: nothing is
	// free, never a wrapped negative reservation freeing escrow.
	d.Totals.Owed, d.Totals.Swept = q, 0
	if r := d.Reserved(); r != maxInt64 {
		t.Fatalf("reserved %d", r)
	}
	if swept, err := rt.Credit(t0, 10, 0, pk(13), "ugnot", alice, 100, ByPacket, "", maxInt64); err != nil || !swept {
		t.Fatalf("a claim took escrow the refunds and claims reserve: %v", err)
	}
	// Statistics saturate.
	d.Totals.Credited = maxInt64 - 1
	d.Totals.Owed = 0
	rt.enqueue(d, t0, 10, 0, pk(14), alice, 50, ByVote)
	if d.Totals.Credited != maxInt64 {
		t.Fatalf("credited %d", d.Totals.Credited)
	}

	// The minted supply: a refund paid beyond a released reservation that
	// would overflow the outstanding supply is parked, never minted past it.
	r2, rt2 := newRoute(t)
	w := rt2.Denom("ibc/WETH")
	rt2.RecordSend(sendRec(1, "ibc/WETH", KindMint, 100))
	rt2.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0) // releases the reservation
	w.Totals.Outstanding = maxInt64 - 50
	r2.Replace("ethereum-1", "ethereum-2", 2, 1000)
	if ps, err := settleProven(rt2, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 100}}, "inc", lockOf(0)); err != nil || len(ps) != 0 || w.Totals.Outstanding != maxInt64-50 {
		t.Fatalf("the outstanding supply wrapped: %v %+v %d", err, ps, w.Totals.Outstanding)
	}
	// Unpaid authorizations saturate: they only bound what is left to
	// resolve.
	if n := boundAdd(maxInt64, 1); n != maxInt64 {
		t.Fatalf("%d", n)
	}
}

// A zero settlement moves nothing, so the escrow's capacity does not gate it:
// with the escrow short of what claims owe (free escrow negative) and the
// incident's deficit accepted, a genuine refund paid in full still settles
// (Codex round 4 #5).
func TestZeroSettlementIgnoresCapacity(t *testing.T) {
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0+Day, 1, pk(1), OutcomeTimeout, false, big) // refunded in full
	mustCredit(t, rt, t0, 5, "ugnot", alice, 1_000, big)    // a claim owes 1000
	rt.RecordLoss(pk(9), "ugnot", 1_000, ChainGno, "inc", "collision")
	rt.Accept("ugnot", 1_000, "inc")
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	// The escrow is empty: free escrow is -1000.
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay}}, "inc", lockOf(0)); err != nil {
		t.Fatal(err)
	}
	if rec, _ := rt.Send(pk(1)); rec.Settlement != SettlePay {
		t.Fatalf("%+v", rec)
	}
}

// settleProven proves for each item the outcome its action needs (a test of
// the actions; TestProvenOutcomes covers the proofs' gate), then settles.
func activeAll(string, uint64) bool { return true }

func settleProven(rt *Route, client string, items []SettleItem, incident string, lock func(string) int64) ([]RefundPayment, error) {
	for _, it := range items {
		r := rt.send(PacketKey(client, it.Seq))
		if r == nil || it.Action == SettleForgedReceive {
			continue
		}
		if it.Action == SettlePay {
			r.Proven = ProvenRefundable
		} else {
			r.Proven = ProvenDelivered
		}
	}
	return rt.SettleRecords(client, items, incident, lock, activeAll)
}

// A settlement's action must match the destination's outcome proven through
// the replacement client; a proof never goes back to an older height; a
// forged receive's loss is booked once, as what its receive paid out (ADR
// pr6375 §7.12 "Proven outcomes", kind 12 action 5).
func TestProvenOutcomes(t *testing.T) {
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rec, _ := rt.Send(pk(1))
	if err := rt.ProveOutcome(pk(1), rec.Packet, ProvenDelivered, 10, "ethereum-2", 0, activeAll); err == nil {
		t.Fatalf("proved the outcome of a live client's send")
	}
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	other := rec.Packet
	other.TimeoutTimestamp++
	if err := rt.ProveOutcome(pk(1), other, ProvenDelivered, 10, "ethereum-2", 0, activeAll); err == nil {
		t.Fatalf("proved with another packet")
	}
	if err := rt.ProveOutcome(pk(1), rec.Packet, ProvenDelivered, 10, "ethereum-2", 0, activeAll); err != nil {
		t.Fatal(err)
	}
	// A proven outcome is final while its verifier is Active (Codex round 5
	// #1): no later proof replaces it.
	if err := rt.ProveOutcome(pk(1), rec.Packet, ProvenRefundable, 11, "ethereum-2", 0, activeAll); err == nil {
		t.Fatalf("a proof replaced a final outcome")
	}
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 1_000}}, "inc", lockOf(big), activeAll); err == nil {
		t.Fatalf("refunded a send proven delivered")
	}
	// The verifier froze or expired between the proof and the settlement:
	// the outcome is void and must be proven again through a healthy client
	// (Codex round 5 #5).
	frozen := func(c string, _ uint64) bool { return c != "ethereum-2" }
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc", lockOf(big), frozen); err == nil {
		t.Fatalf("settled on an outcome its frozen verifier proved")
	}
	if err := rt.ProveOutcome(pk(1), rec.Packet, ProvenDelivered, 12, "ethereum-3", 0, frozen); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc", lockOf(big), frozen); err != nil {
		t.Fatal(err)
	}

	// The verifier was recovered between the proof and the settlement (Codex
	// round 6 #2): Active again, but under a new trust generation, so what it
	// proved before is void.
	reg3, rt3 := newRoute(t)
	rt3.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rec3, _ := rt3.Send(pk(1))
	reg3.Replace("ethereum-1", "ethereum-2", 0, 1000)
	gen := uint64(4)
	current := func(_ string, g uint64) bool { return g == gen }
	if err := rt3.ProveOutcome(pk(1), rec3.Packet, ProvenDelivered, 10, "ethereum-2", gen, current); err != nil {
		t.Fatal(err)
	}
	gen++ // recovered
	if _, err := rt3.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc", lockOf(big), current); err == nil {
		t.Fatalf("settled on an outcome proven before its verifier's recovery")
	}
	if err := rt3.ProveOutcome(pk(1), rec3.Packet, ProvenDelivered, 20, "ethereum-2", gen, current); err != nil {
		t.Fatal(err)
	}
	if _, err := rt3.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc", lockOf(big), current); err != nil {
		t.Fatal(err)
	}

	// Forged receives: a paid claim's installments and a paid sweep entry.
	r2, rt2 := newRoute(t)
	mustCredit(t, rt2, t0, 5, "ugnot", alice, 3_000, big)
	rt2.PayClaims(t0+Day, 0, t0, "ugnot", 1, big)
	c, _ := rt2.Claim(pk(5))
	rt2.Credit(t0, 10, 0, pk(6), "ugnot", alice, 400, ByPacket, "bridge realm", big)
	rt2.PaySweeps([]string{pk(6)}, bob, big)
	r2.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := rt2.SettleRecords("ethereum-1", []SettleItem{{Seq: 5, Action: SettleForgedReceive, Amount: c.Paid + 1}}, "inc", lockOf(big), activeAll); err == nil {
		t.Fatalf("booked more than the receive paid out")
	}
	if _, err := rt2.SettleRecords("ethereum-1", []SettleItem{{Seq: 5, Action: SettleForgedReceive, Amount: c.Paid}, {Seq: 6, Action: SettleForgedReceive, Amount: 400}}, "inc", lockOf(big), activeAll); err != nil {
		t.Fatal(err)
	}
	if rt2.Denom("ugnot").Totals.Lost != c.Paid+400 {
		t.Fatalf("%+v", rt2.Denom("ugnot").Totals)
	}
	if _, err := rt2.SettleRecords("ethereum-1", []SettleItem{{Seq: 6, Action: SettleForgedReceive, Amount: 400}}, "inc", lockOf(big), activeAll); err == nil {
		t.Fatalf("booked a forged receive twice")
	}
	if rt2.Voidable(pk(5), true) {
		t.Fatalf("a forged receive's claim can be voided as forged again")
	}
	if _, err := rt2.SettleRecords("ethereum-1", []SettleItem{{Seq: 7, Action: SettleForgedReceive, Amount: 1}}, "inc", lockOf(big), activeAll); err == nil {
		t.Fatalf("booked a receive that paid nothing")
	}
	// The forged claim's remainder is gone: through the reopening, no later
	// claim payout pays it (Codex round 5 #2).
	c5, _ := rt2.Claim(pk(5))
	if c5.State != Forged || rt2.Denom("ugnot").Totals.Owed != 0 {
		t.Fatalf("%+v %+v", c5, rt2.Denom("ugnot").Totals)
	}
	if _, done, err := rt2.Reopen(); err != nil || !done {
		t.Fatalf("reopen: %v", err)
	}
	if ps, _ := rt2.PayClaims(t0+10*Day, 0, t0, "ugnot", 20, big); len(ps) != 0 {
		t.Fatalf("paid a forged receive's remainder: %+v", ps)
	}
}

// A settlement's refund never takes the escrow the claims reserve, even when
// claims and refunds together exceed what an int64 holds (Codex round 5 #3).
func TestSettlementReserveBeyondMaxInt64(t *testing.T) {
	r, rt := newRoute(t)
	d := rt.Denom("ugnot")
	const big5 = int64(5_000_000_000_000_000_000)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, big5))
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, 0) // queued under a hold
	d.Totals.Owed = big5                             // claims owe 5e18 too
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: big5}}, "inc", lockOf(maxInt64)); err == nil {
		t.Fatalf("paid a refund out of the escrow the claims reserve")
	}
}

// A refund paid for a delivered packet is booked only by settling its record
// (action 4), never recorded on its own, which would leave the record
// unsettled and the route closed (Codex round 5 #7).
func TestRefundForDeliveredOnlyBySettlement(t *testing.T) {
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0+Day, 1, pk(1), OutcomeTimeout, false, big) // refunded
	if err := rt.RecordLoss(pk(1), "ugnot", 1_000, ChainGno, "inc", CauseRefundForDelivered); err == nil {
		t.Fatalf("recorded a refund-for-delivered loss outside its settlement")
	}
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettleLoss, Amount: 1_000}}, "inc", lockOf(big)); err != nil {
		t.Fatal(err)
	}
	if _, done, err := rt.Reopen(); err != nil || !done || rt.Denom("ugnot").Totals.Lost != 1_000 {
		t.Fatalf("%v %+v", err, rt.Denom("ugnot").Totals)
	}
}

// One loss per packet and direction, whatever the path (Codex round 9 #3): a
// paid forged receive is booked by its void or its settlement, never also by
// a recorded loss, in either order; a send's loss by its settlement or a
// recorded Ethereum loss, once.
func TestOneLossPerPacket(t *testing.T) {
	setup := func() (*Registry, *Route, int64) {
		r, rt := newRoute(t)
		mustCredit(t, rt, t0, 5, "ugnot", alice, 3_000, big)
		rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, big)
		c, _ := rt.Claim(pk(5))
		return r, rt, c.Paid
	}
	// A recorded loss of a represented receive is refused outright.
	_, rt, _ := setup()
	if err := rt.RecordLoss(pk(5), "ugnot", 100, ChainGno, "inc", "forged-delivery"); err == nil {
		t.Fatalf("recorded a loss of a represented receive")
	}
	// Void as forged, then settle as a forged receive: once.
	r, rt, paid := setup()
	if err := rt.Void([]string{pk(5)}, true, "inc"); err != nil {
		t.Fatal(err)
	}
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 5, Action: SettleForgedReceive, Amount: paid}}, "inc", lockOf(big), activeAll); err == nil {
		t.Fatalf("settled a voided receive's loss again")
	}
	if err := rt.RecordLoss(pk(5), "ugnot", paid, ChainGno, "inc", "forged-delivery"); err == nil {
		t.Fatalf("recorded a voided receive's loss again")
	}
	if rt.Denom("ugnot").Totals.Lost != paid {
		t.Fatalf("lost %d", rt.Denom("ugnot").Totals.Lost)
	}
	// Settle as a forged receive, then void as forged: once.
	r, rt, paid = setup()
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 5, Action: SettleForgedReceive, Amount: paid}}, "inc", lockOf(big), activeAll); err != nil {
		t.Fatal(err)
	}
	if rt.Void([]string{pk(5)}, true, "inc") == nil || rt.RecordLoss(pk(5), "ugnot", paid, ChainGno, "inc", "collision") == nil {
		t.Fatalf("booked a settled receive's loss again")
	}
	if rt.Denom("ugnot").Totals.Lost != paid {
		t.Fatalf("lost %d", rt.Denom("ugnot").Totals.Lost)
	}
	// A send: a recorded Ethereum loss, then the settlement's, and the
	// reverse, once each; the send and receive spaces stay apart.
	for _, recordFirst := range []bool{true, false} {
		r, rt := newRoute(t)
		rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
		rt.Settle(t0, 1, pk(1), OutcomeTimeout, false, big)
		rt.PayRefunds(t0+Day, "ugnot", 5, false, big)
		r.Replace("ethereum-1", "ethereum-2", 0, 1000)
		rec, _ := rt.Send(pk(1))
		record := func() error { return rt.RecordLoss(pk(1), "ugnot", rec.Refunded, ChainEthereum, "inc", "collision") }
		settle := func() error {
			_, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettleLoss, Amount: rec.Refunded}}, "inc", lockOf(big))
			return err
		}
		first, second := settle, record
		if recordFirst {
			first, second = record, settle
		}
		if rec.Refunded <= 0 {
			t.Fatalf("no refund paid: %+v", rec)
		}
		if err := first(); err != nil {
			t.Fatal(err)
		}
		if second() == nil {
			t.Fatalf("booked a send's loss twice (record first: %v)", recordFirst)
		}
		if !rt.LossBooked(DirSend, pk(1)) || rt.LossBooked(DirRecv, pk(1)) {
			t.Fatalf("directions")
		}
	}
}

// The ledger keeps a loss per packet and direction (Codex round 10 #2): the
// inbound and the outbound packet of one client and sequence are two
// entries, in either order, and the entries sum to the totals.
func TestLossesByDirection(t *testing.T) {
	for _, gnoFirst := range []bool{true, false} {
		r, rt := newRoute(t)
		in := func() error { return rt.RecordLoss(pk(9), "ugnot", 100, ChainGno, "inc", "forged-delivery") }
		out := func() error { return rt.RecordLoss(pk(9), "ugnot", 200, ChainEthereum, "inc", "forged-delivery") }
		first, second := out, in
		if gnoFirst {
			first, second = in, out
		}
		if err := first(); err != nil {
			t.Fatal(err)
		}
		if err := second(); err != nil {
			t.Fatal(err)
		}
		js := (Reader{r: r}).LossesJSON("ethereum-1", "")
		if strings.Count(js, `"key":`) != 2 || !strings.Contains(js, `"amount":100`) || !strings.Contains(js, `"amount":200`) {
			t.Fatalf("ledger: %s", js)
		}
		if rt.Denom("ugnot").Totals.Lost != 300 || rt.Incident("ugnot", "inc").Lost != 300 {
			t.Fatalf("totals: %+v", rt.Denom("ugnot").Totals)
		}
	}
}

// The loss ledger pages by an explicit cursor (Codex round 11 #3): with both
// directions and more entries than a page, following next covers every
// entry exactly once, and the entries sum to the totals.
func TestLossPages(t *testing.T) {
	r, rt := newRoute(t)
	n := PageLines + 7
	for i := 1; i <= n; i++ {
		if err := rt.RecordLoss(pk(uint64(i)), "ugnot", 1, ChainGno, "inc", "forged-delivery"); err != nil {
			t.Fatal(err)
		}
		if err := rt.RecordLoss(pk(uint64(i)), "ugnot", 2, ChainEthereum, "inc", "collision"); err != nil {
			t.Fatal(err)
		}
	}
	seen := map[string]bool{}
	var sum int64
	from, pages := "", 0
	for {
		js := (Reader{r: r}).LossesJSON("ethereum-1", from)
		pages++
		for _, part := range strings.Split(js, "},{") {
			k := part[strings.Index(part, `"key":"`)+7:]
			k = k[:strings.Index(k, `"`)]
			d := part[strings.Index(part, `"direction":"`)+13:]
			d = d[:strings.Index(d, `"`)]
			if seen[d+k] {
				t.Fatalf("%s %s listed twice", d, k)
			}
			seen[d+k] = true
			a := part[strings.Index(part, `"amount":`)+9:]
			a = a[:strings.Index(a, ",")]
			v, _ := strconv.ParseInt(a, 10, 64)
			sum += v
		}
		next := js[strings.LastIndex(js, `"next":"`)+8:]
		next = next[:strings.Index(next, `"`)]
		next = strings.ReplaceAll(next, "\\"+"u007c", "|") // the cursor is a JSON string
		if next == "" {
			break
		}
		from = next
	}
	if len(seen) != 2*n || sum != rt.Denom("ugnot").Totals.Lost || sum != int64(3*n) || pages < 3 {
		t.Fatalf("covered %d of %d, sum %d, pages %d", len(seen), 2*n, sum, pages)
	}
}

// A settlement's escrow check counts every reservation the whole batch
// releases (Codex round 12 #3): with an escrow of 1,000 and two queued
// refunds of 1,000, paying genuine refund A and rejecting delivered B is
// solvent, in either item order.
func TestSettlementCountsEveryRelease(t *testing.T) {
	for _, payFirst := range []bool{true, false} {
		r, rt := newRoute(t)
		rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
		rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 1_000))
		rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, 0) // queued under a hold
		rt.Settle(t0, 1, pk(2), OutcomeTimeout, true, 0)
		r.Replace("ethereum-1", "ethereum-2", 0, 1000)
		rt.send(pk(1)).Proven = ProvenRefundable
		rt.send(pk(2)).Proven = ProvenDelivered
		pay, reject := SettleItem{Seq: 1, Action: SettlePay, Amount: 1_000}, SettleItem{Seq: 2, Action: SettleReject}
		items := []SettleItem{reject, pay}
		if payFirst {
			items = []SettleItem{pay, reject}
		}
		ps, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(1_000), activeAll)
		if err != nil || len(ps) != 1 || ps[0].Amount != 1_000 || rt.Denom("ugnot").Totals.QueuedRefunds != 0 {
			t.Fatalf("pay first %v: %v %+v", payFirst, err, ps)
		}
	}
	// One escrow short of the payment is still refused.
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, 0)
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	rt.send(pk(1)).Proven = ProvenRefundable
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 1_000}}, "inc", lockOf(999), activeAll); err == nil {
		t.Fatalf("paid beyond the escrow")
	}
}

// A forged-receive settlement of a claim moved to the sweep books what the
// claim paid and drops the live remainder, so no decision pays it.
func TestSettleForgedReceiveOfMovedClaim(t *testing.T) {
	r, rt := newRoute(t)
	lock := int64(100_000) // a recipient 2500 a day: paid in part
	mustCredit(t, rt, t0, 5, "ugnot", alice, 3_000, lock)
	rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, lock)
	c, _ := rt.Claim(pk(5))
	if c.Paid == 0 || c.Remaining() == 0 {
		t.Fatalf("setup: %+v", c)
	}
	isAlice := func(a address) bool { return a == alice }
	if _, moved, err := rt.PayClaimsSweeping(t0+2*Day, 0, t0, "ugnot", 1, lock, isAlice); err != nil || len(moved) != 1 {
		t.Fatalf("%v %v", moved, err)
	}
	d := rt.Denom("ugnot")
	swept := d.Totals.Swept
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 5, Action: SettleForgedReceive, Amount: c.Paid}}, "inc", lockOf(big), activeAll); err != nil {
		t.Fatal(err)
	}
	e, _ := rt.Sweep(pk(5))
	if !e.Voided || d.Totals.Swept != swept-c.Remaining() || d.Totals.Lost != c.Paid {
		t.Fatalf("%+v %+v", e, d.Totals)
	}
	if _, err := rt.PaySweeps([]string{pk(5)}, bob, big); err == nil {
		t.Fatalf("paid a forged receive's remainder")
	}
}

// Every minted payout checks the outstanding supply's headroom first (Codex
// round 26 #1): with a supply cap at MaxInt64, a forged success releases a
// returning send's reservation, an owed sweep entry is booked, and the
// genuine refund is settled; paying the sweep entry would then overflow the
// outstanding supply, so the sweep payment is refused whole, the entry kept,
// and claim installments are capped to the headroom, their remainder kept.
func TestMintedPayoutHeadroom(t *testing.T) {
	const five = int64(5_000_000_000_000_000_000)
	r, rt := newRoute(t)
	cfg := DenomConfig{Kind: KindMint, CapFloor: 4_000_000_000_000_000_000, SupplyCap: maxInt64, Fee: 10, FeeFloor: 1, RefundCap: 4_000_000_000_000_000_000}
	if err := rt.SetDenom("ibc/BIG", cfg, t0, 0, five); err != nil {
		t.Fatal(err)
	}
	d := rt.Denom("ibc/BIG")
	if err := rt.RecordSend(sendRec(1, "ibc/BIG", KindMint, five)); err != nil {
		t.Fatal(err)
	}
	rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0) // forged: the reservation released
	if swept, err := rt.Credit(t0, 10, 0, pk(20), "ibc/BIG", alice, five, ByPacket, "bridge realm", 0); err != nil || !swept {
		t.Fatalf("sweep entry: %v", err)
	}
	mustCredit(t, rt, t0, 21, "ibc/BIG", bob, 1_000, 0)
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: five}}, "inc", lockOf(0)); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.PaySweeps([]string{pk(20)}, carol, 0); err == nil {
		t.Fatalf("the sweep payment overflowed the outstanding supply")
	}
	if e, _ := rt.Sweep(pk(20)); e.Paid || e.Voided || e.Amount != five {
		t.Fatalf("the entry changed: %+v", e)
	}
	// A claim installment is capped to the headroom left.
	d.Totals.Outstanding = maxInt64 - 100
	ps, err := rt.PayClaims(t0+Day, 0, t0, "ibc/BIG", 1, 0)
	if err != nil || len(ps) != 1 || ps[0].Fee+ps[0].Amount != 100 || d.Totals.Outstanding != maxInt64 {
		t.Fatalf("%v %+v outstanding %d", err, ps, d.Totals.Outstanding)
	}
	c, _ := rt.Claim(pk(21))
	if c.Remaining() != 900 || c.State != Open {
		t.Fatalf("the claim lost its entitlement: %+v", c)
	}
	if ps, _ := rt.PayClaims(t0+2*Day, 0, t0, "ibc/BIG", 1, 0); len(ps) != 0 {
		t.Fatalf("paid past the outstanding supply: %+v", ps)
	}
}

// A genuine settlement refund the outstanding supply cannot hold is parked,
// not refused (design review #3): the integer capacity is spent (a forged
// success released the send's reservation, and forged credits took what it
// freed), no unpaid claim is left to reduce, and the route stays closed until
// its sends are settled. The parked refund settles its record, so the route
// reopens; it is owed, queued and reserved against the supply cap, so no
// credit takes the capacity it needs; a voucher return frees capacity, and
// the queued refund is then paid in full.
func TestParkedSettlementRefund(t *testing.T) {
	const five = int64(5_000_000_000_000_000_000)
	const a = int64(1_000)
	r, rt := newRoute(t)
	cfg := DenomConfig{Kind: KindMint, CapFloor: maxInt64, SupplyCap: maxInt64, Fee: 10, FeeFloor: 1, RefundCap: 24_000}
	if err := rt.SetDenom("ibc/BIG", cfg, t0, 0, maxInt64); err != nil {
		t.Fatal(err)
	}
	d := rt.Denom("ibc/BIG")
	// A holder burns a (a return); a forged success releases its reservation.
	if err := rt.RecordSend(sendRec(1, "ibc/BIG", KindMint, a)); err != nil {
		t.Fatal(err)
	}
	rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0)
	// Forged credits take the freed capacity: the supply is full again.
	mustCredit(t, rt, t0, 30, "ibc/BIG", bob, a, 0)
	if ps, err := rt.PayClaims(t0+Day, 0, t0, "ibc/BIG", 1, 0); err != nil || len(ps) != 1 || d.Totals.Outstanding != maxInt64 || d.Totals.Owed != 0 {
		t.Fatalf("setup: %v %+v %+v", err, ps, d.Totals)
	}
	// The replacement proves the return refundable: its genuine refund
	// cannot be minted now, so it is parked.
	r.Replace("ethereum-1", "ethereum-2", 0, 1000)
	ps, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: a}}, "inc", lockOf(0))
	if err != nil || len(ps) != 0 {
		t.Fatalf("settlement: %v %+v", err, ps)
	}
	rec, _ := rt.Send(pk(1))
	if rec.Settlement != SettlePay || rec.Payment != PayQueued || rec.Reservation != a || d.Totals.QueuedRefunds != a || d.Totals.Returning != a {
		t.Fatalf("parked: %+v totals %+v", rec, d.Totals)
	}
	// Settled: it no longer blocks the reopening.
	if _, done, err := rt.Reopen(); err != nil || !done {
		t.Fatalf("reopen: %v %v", done, err)
	}
	// The reserved refund counts against the supply cap: no credit takes it.
	if err := rt.CheckCredit("ibc/BIG", 1); err == nil {
		t.Fatalf("a credit took the capacity the parked refund needs")
	}
	// No capacity yet: nothing is paid, the refund stays owed.
	if ps, _ := rt.PayRefunds(t0+2*Day, "ibc/BIG", 20, false, 0); len(ps) != 0 {
		t.Fatalf("minted past the supply: %+v", ps)
	}
	// A voucher return over the new client burns 2a: the parked refund is
	// paid in full.
	ret := sendRec(2, "ibc/BIG", KindMint, 2*a)
	ret.Packet.SourceClient = "ethereum-2"
	ret.Key, ret.Commitment = PacketKey("ethereum-2", 2), types.CommitPacket(ret.Packet)
	if err := rt.RecordSend(ret); err != nil {
		t.Fatal(err)
	}
	ps, err = rt.PayRefunds(t0+2*Day, "ibc/BIG", 20, false, 0)
	if err != nil || len(ps) != 1 || ps[0].Key != pk(1) || ps[0].Amount != a {
		t.Fatalf("paid: %v %+v", err, ps)
	}
	rec, _ = rt.Send(pk(1))
	if rec.Payment != PayReconciled || rec.Refunded != a || rec.Reservation != 0 || d.Totals.QueuedRefunds != 0 ||
		d.Totals.Returning != 2*a || d.Totals.Outstanding != maxInt64-a {
		t.Fatalf("after: %+v totals %+v", rec, d.Totals)
	}
	if rt.OpenSends("ethereum-1") != 0 {
		t.Fatalf("open sends %d", rt.OpenSends("ethereum-1"))
	}
}
