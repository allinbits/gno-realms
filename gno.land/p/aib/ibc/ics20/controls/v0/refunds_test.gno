package controls

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
)

// big is a lock that covers every refund.
const big = uint256(1_000_000_000)

func sendRec(seq uint64, denom, kind string, amount uint256) SendRecord {
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
	var paid uint256
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

func lockOf(l uint256) func(string) uint256 { return func(string) uint256 { return l } }

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
	if err := replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000); err != nil {
		t.Fatal(err)
	}
	before := d.Totals
	bad := [][]SettleItem{
		{{Seq: 3, Action: SettleReject}},                                       // no queued refund
		{{Seq: 2, Action: SettlePay, Amount: 1_000}},                           // cut short
		{{Seq: 2, Action: SettlePay, Amount: 3_001}},                           // more than owed
		{{Seq: 1, Action: SettleLoss, Amount: 1}},                              // not what was paid
		{{Seq: 2, Action: SettleLoss, Amount: 0}},                              // nothing was paid
		{{Seq: 1, Action: SettleDelivered, Amount: 1}},                         // an amount
		{{Seq: 1, Action: 5}},                                                  // unknown
		{{Seq: 9, Action: SettleDelivered}},                                    // no record
		{{Seq: 3, Action: SettleDelivered}, {Seq: 3, Action: SettleDelivered}}, // twice
	}
	for i, b := range bad {
		if _, err := settleProven(rt, "ethereum-1", b, "inc-1", lockOf(d.Reserved()-1_000)); err == nil {
			t.Fatalf("bad settlement %d applied", i)
		}
	}
	// The preparation reserved 4's and 5's 3000 each, which their own
	// settlement releases: 5000 left free once it applies, short of the
	// 6000 both refunds need. Paying 4 would leave 5 with 2000 behind its
	// 3000, so both park rather than the settlement be refused (code
	// review r53 #1).
	rt.send(pk(4)).Proven, rt.send(pk(5)).Proven = ProvenRefundable, ProvenRefundable
	if msg := planParks(rt, []SettleItem{{Seq: 4, Action: SettlePay, Amount: 3_000}, {Seq: 5, Action: SettlePay, Amount: 3_000}}, lockOf(d.Reserved()-1_000), activeAll, 0, 4, 5); msg != "" {
		t.Fatal(msg)
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
	// The suspect interval starts after the success (processed at height
	// 1): it is trusted, nothing reserves it again.
	replaceReady(reg, "ethereum-1", "ethereum-2", 2, 1000)
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
	if err := replaceReady(r, "ethereum-1", "ethereum-2", -1, 1000); err == nil {
		t.Fatalf("a negative suspect height")
	}
	if err := replaceReady(r, "ethereum-1", "ethereum-2", 20, 1000); err != nil {
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

// Every aggregate a check reads stays exact or refuses (Codex round 4 #1,
// class A): the open sends, the queued refunds and the liabilities are
// exact past int64, a credit that would pass the maximum is refused, a
// reservation that would pass it saturates (nothing is free), statistics
// saturate, and a minted refund mints past int64 whole.
func TestAggregatesNeverWrap(t *testing.T) {
	const q = uint256(1) << 62
	_, rt := newRoute(t)
	d := rt.Denom("ugnot")
	for i := 0; i < 3; i++ {
		if err := rt.RecordSend(sendRec(uint64(i+1), "ugnot", KindUnescrow, q)); err != nil {
			t.Fatalf("send %d: %v", i+1, err)
		}
	}
	if d.Totals.InFlight != 3*q {
		t.Fatalf("in flight %d", d.Totals.InFlight)
	}
	rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, 0)
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, 0)
	rt.Settle(t0, 1, pk(3), OutcomeTimeout, true, 0)
	if d.Totals.QueuedRefunds != 2*q || d.Totals.InFlight != 2*q {
		t.Fatalf("queued %d in flight %d", d.Totals.QueuedRefunds, d.Totals.InFlight)
	}
	// Claims and sweep entries: the credit that would overflow is refused.
	if _, err := rt.Credit(t0, 10, 0, pk(10), "ugnot", alice, maxAmount-1, ByPacket, "bridge realm", 0); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.Credit(t0, 10, 0, pk(11), "ugnot", alice, 2, ByPacket, "bridge realm", 0); err == nil {
		t.Fatalf("liabilities wrapped")
	}
	if err := rt.CreditPending(t0, 10, 0, pk(12), "ugnot", alice, 2, 2, maxAmount); err == nil {
		t.Fatalf("liabilities wrapped by a pending credit")
	}
	// The reservation of claims and refunds together saturates: nothing is
	// free, never a wrapped reservation freeing escrow.
	_, rt3 := newRoute(t)
	d3 := rt3.Denom("ugnot")
	d3.Totals.Owed, d3.Totals.ProvenOwed = 2, maxAmount-1
	if r := d3.Reserved(); r != maxAmount {
		t.Fatalf("reserved %d", r)
	}
	if swept, err := rt3.Credit(t0, 10, 0, pk(13), "ugnot", alice, 100, ByPacket, "", maxAmount); err != nil || !swept {
		t.Fatalf("a claim took escrow the refunds and claims reserve: %v", err)
	}
	// Statistics saturate.
	d3.Totals.Credited = maxAmount - 1
	rt3.enqueue(d3, t0, 10, 0, pk(14), alice, 50, ByVote)
	if d3.Totals.Credited != maxAmount {
		t.Fatalf("credited %d", d3.Totals.Credited)
	}
	// The minted supply: a refund paid beyond a released reservation mints
	// past int64, exactly.
	r2, rt2 := newRoute(t)
	w := rt2.Denom("ibc/WETH")
	rt2.RecordSend(sendRec(1, "ibc/WETH", KindMint, 100))
	rt2.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0) // releases the reservation
	w.Totals.Outstanding = maxInt64 - 50
	replaceReady(r2, "ethereum-1", "ethereum-2", 2, 1000)
	if ps, err := settleProven(rt2, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 100}}, "inc", lockOf(0)); err != nil || len(ps) != 1 || w.Totals.Outstanding != maxInt64+50 {
		t.Fatalf("the outstanding supply: %v %+v %d", err, ps, w.Totals.Outstanding)
	}
	// Unpaid authorizations saturate: they only bound what is left to
	// resolve.
	if n := boundAdd(maxAmount, 1); n != maxAmount {
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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

func settleProven(rt *Route, client string, items []SettleItem, incident string, lock func(string) uint256) ([]RefundPayment, error) {
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
	replaceReady(reg3, "ethereum-1", "ethereum-2", 0, 1000)
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
	replaceReady(r2, "ethereum-1", "ethereum-2", 0, 1000)
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
// claims and refunds together exceed what the escrow (an int64 bank balance)
// holds (Codex round 5 #3).
func TestSettlementReserveBeyondMaxInt64(t *testing.T) {
	r, rt := newRoute(t)
	d := rt.Denom("ugnot")
	const big5 = uint256(5_000_000_000_000_000_000)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, big5))
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, 0) // queued under a hold
	d.Totals.Owed = big5                             // claims owe 5e18 too
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	ps, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: big5}}, "inc", lockOf(maxInt64))
	if r1, _ := rt.Send(pk(1)); err != nil || len(ps) != 0 || r1.Payment != PayQueued || r1.Settlement != SettlePay || d.Totals.QueuedRefunds != big5 {
		t.Fatalf("paid a refund out of the escrow the claims reserve, or refused to park it: %v %+v", err, ps)
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
	setup := func() (*Registry, *Route, uint256) {
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
		out := func() error {
			return rt.RecordLoss(pk(9), "ugnot", 200, ChainEthereum, "inc-mirror", "forged-delivery")
		}
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
		if strings.Count(js, `"key":`) != 2 || !strings.Contains(js, `"amount":"100"`) || !strings.Contains(js, `"amount":"200"`) {
			t.Fatalf("ledger: %s", js)
		}
		if rt.Denom("ugnot").Totals.Lost != 300 || rt.Incident("ugnot", "inc").Lost != 100 || rt.Incident("ugnot", "inc-mirror").Lost != 200 || !rt.Incident("ugnot", "inc-mirror").Mirror {
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
		if err := rt.RecordLoss(pk(uint64(i)), "ugnot", 2, ChainEthereum, "inc-mirror", "collision"); err != nil {
			t.Fatal(err)
		}
	}
	seen := map[string]bool{}
	var sum uint256
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
			a := part[strings.Index(part, `"amount":"`)+10:]
			a = a[:strings.Index(a, `"`)]
			v, _ := strconv.ParseUint256(a, 10)
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
	if len(seen) != 2*n || sum != rt.Denom("ugnot").Totals.Lost || sum != uint256(3*n) || pages < 3 {
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
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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
	// One escrow short of the payment parks it, owed, and paid once the
	// escrow is whole.
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, 0)
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	rt.send(pk(1)).Proven = ProvenRefundable
	ps, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 1_000}}, "inc", lockOf(999), activeAll)
	if r1, _ := rt.Send(pk(1)); err != nil || len(ps) != 0 || r1.Payment != PayQueued || rt.Denom("ugnot").Totals.QueuedRefunds != 1_000 {
		t.Fatalf("paid beyond the escrow, or refused to park: %v %+v", err, ps)
	}
	if ps, err := rt.PayRefunds(t0+Day, "ugnot", 1, false, 1_000); err != nil || len(ps) != 1 || ps[0].Amount != 1_000 {
		t.Fatalf("the parked refund was not paid: %v %+v", err, ps)
	}
}

// planParks plans items and reports, unless the plan parks exactly the
// sequences parked and pays the paid others, what it does instead.
func planParks(rt *Route, items []SettleItem, lock func(string) uint256, trusted func(string, uint64) bool, paid int, parked ...uint64) string {
	plan, err := rt.PlanSettlement("ethereum-1", items, "inc", lock, trusted)
	if err != nil {
		return "refused: " + err.Error()
	}
	if len(plan.Payments) != paid || len(plan.parked) != len(parked) {
		return ufmt.Sprintf("paid %+v, parked %v", plan.Payments, plan.parked)
	}
	for _, seq := range parked {
		if !plan.parked[seq] {
			return ufmt.Sprintf("%d not parked: %v", seq, plan.parked)
		}
	}
	return ""
}

// A forged-receive settlement of a claim moved to the sweep books what the
// claim paid and drops the live remainder, so no decision pays it.
func TestSettleForgedReceiveOfMovedClaim(t *testing.T) {
	r, rt := newRoute(t)
	lock := uint256(100_000) // a recipient 2500 a day: paid in part
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
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
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

// Minted payouts are bounded by the supply cap at admission only: with the
// outstanding supply past int64, a forged success releasing a return's
// reservation, an owed sweep entry and a claim are booked, the genuine
// refund is settled and paid whole, the sweep payment is paid whole, and
// the claim is paid within the meters, nothing cut to any headroom; the
// supply counts exactly past 2^63.
func TestMintedPayoutsUnbounded(t *testing.T) {
	const five = uint256(5_000_000_000_000_000_000)
	const day = uint256(4_000_000_000_000_000_000)
	r, rt := newRoute(t)
	cfg := DenomConfig{Kind: KindMint, CapFloor: day, SupplyCap: maxAmount, Fee: 10, FeeFloor: 1, RefundCap: day}
	if err := rt.SetDenom("ibc/BIG", cfg, t0, 0, 3*five); err != nil {
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
	mustCredit(t, rt, t0, 21, "ibc/BIG", bob, five, 0)
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	if ps, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: five}}, "inc", lockOf(0)); err != nil || len(ps) != 1 || ps[0].Amount != five || d.Totals.Outstanding != 3*five {
		t.Fatalf("the settled refund: %v %+v %+v", err, ps, d.Totals)
	}
	if ps, err := rt.PaySweeps([]string{pk(20)}, carol, 0); err != nil || len(ps) != 1 || ps[0].Amount != five || d.Totals.Outstanding != 4*five {
		t.Fatalf("the sweep payment: %v %+v %+v", err, ps, d.Totals)
	}
	// A claim installment is bounded by the meters alone: the recipient's
	// quarter of a day cap after a day.
	ps, err := rt.PayClaims(t0+Day, 0, t0, "ibc/BIG", 1, 0)
	if err != nil || len(ps) != 1 || ps[0].Fee+ps[0].Amount != day/4 || d.Totals.Outstanding != 4*five+day/4 {
		t.Fatalf("%v %+v outstanding %d", err, ps, d.Totals.Outstanding)
	}
	if c, _ := rt.Claim(pk(21)); c.Remaining() != five-day/4 || c.State != Open {
		t.Fatalf("the claim: %+v", c)
	}
}

// The checks on every path keep their indexes in step instead of scanning
// (design review #5): whether a denom has an unresolved loss is a counter
// (ExposureClosed reads it in constant work, however many denoms the route
// enables), a queued refund leaves the queue by its key (a settlement of the
// last of many queued refunds reads no other), and the retired clients that
// block a reopening are indexed (however many replacements the route saw).
func TestBoundedIndexes(t *testing.T) {
	r, rt := newRoute(t)
	for i := 0; i < 40; i++ {
		c := gnot()
		c.Remote = "0x0000000000000000000000000000000000c0" + strconv.Itoa(1000+i)
		if err := rt.SetDenom("u"+strconv.Itoa(i), c, t0, 0, 0); err != nil {
			t.Fatal(err)
		}
	}
	// A loss of the last denom closes exposure; accepting it reopens.
	if err := rt.RecordLoss("ethereum-1/00000000000000000901", "u39", 10, ChainEthereum, "inc", "collision"); err != nil {
		t.Fatal(err)
	}
	if !rt.ExposureClosed() || rt.unresolvedDenoms != 1 {
		t.Fatalf("closed %v count %d", rt.ExposureClosed(), rt.unresolvedDenoms)
	}
	if err := rt.Accept("u39", 10, "inc"); err != nil || rt.ExposureClosed() || rt.unresolvedDenoms != 0 {
		t.Fatalf("after accepting: %v closed %v count %d", err, rt.ExposureClosed(), rt.unresolvedDenoms)
	}

	// 60 queued refunds; the last leaves the queue by its key.
	for i := uint64(1); i <= 60; i++ {
		rt.RecordSend(sendRec(i, "ugnot", KindUnescrow, 100))
		rt.Settle(t0, 1, pk(i), OutcomeTimeout, true, big) // queued under a hold
	}
	d := rt.Denom("ugnot")
	if d.refundQueue.Size() != 60 || d.refundIdx.Size() != 60 {
		t.Fatalf("queue %d index %d", d.refundQueue.Size(), d.refundIdx.Size())
	}

	// Many replacements: only the client with an open record blocks.
	for i := 2; i <= 30; i++ {
		if err := replaceReady(r, "ethereum-1", "ethereum-"+strconv.Itoa(i), 0, int64(1000+i)); err != nil {
			t.Fatal(err)
		}
	}
	if rt.blocking.Size() != 1 || rt.reopenBlocker() == nil || !strings.Contains(rt.reopenBlocker().Error(), "retired client ethereum-1 ") {
		t.Fatalf("blocking %d: %v", rt.blocking.Size(), rt.reopenBlocker())
	}
	var items []SettleItem
	for i := uint64(1); i <= 60; i++ {
		items = append(items, SettleItem{Seq: i, Action: SettlePay, Amount: 100})
		if len(items) == MaxKeys || i == 60 {
			if _, err := settleProven(rt, "ethereum-1", items, "inc", lockOf(big)); err != nil {
				t.Fatal(err)
			}
			items = nil
		}
	}
	if d.refundQueue.Size() != 0 || d.refundIdx.Size() != 0 || d.Totals.QueuedRefunds != 0 {
		t.Fatalf("queue %d index %d queued %d", d.refundQueue.Size(), d.refundIdx.Size(), d.Totals.QueuedRefunds)
	}
	if rt.blocking.Size() != 0 || rt.reopenBlocker() != nil {
		t.Fatalf("still blocking: %v", rt.reopenBlocker())
	}
}

// A settlement checks its reservations net (Codex round 31 #2): a genuine
// refund above MaxInt64/2 whose own reservation covers it settles and is
// paid; in a batch mixing a covered refund and one whose reservation a
// forged success released, both are paid in either order, the supply exact
// past int64.
func TestSettlementNetReservations(t *testing.T) {
	const five, three = uint256(5_000_000_000_000_000_000), uint256(3_000_000_000_000_000_000)
	setup := func() (*Route, *Denom) {
		r, rt := newRoute(t)
		cfg := DenomConfig{Kind: KindMint, CapFloor: maxInt64, SupplyCap: maxInt64, Fee: 10, FeeFloor: 1, RefundCap: maxInt64}
		if err := rt.SetDenom("ibc/BIG", cfg, t0, 0, five+three); err != nil {
			t.Fatal(err)
		}
		rt.RecordSend(sendRec(1, "ibc/BIG", KindMint, five))  // still reserved
		rt.RecordSend(sendRec(2, "ibc/BIG", KindMint, three)) // a forged success releases it
		rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, 0)
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
		return rt, rt.Denom("ibc/BIG")
	}

	// Alone: the whole of the supply burned into one return comes back.
	rt, d := setup()
	if d.Totals.Outstanding != 0 || d.Totals.Returning != five {
		t.Fatalf("setup %+v", d.Totals)
	}
	ps, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: five}}, "inc", lockOf(0))
	if err != nil || len(ps) != 1 || ps[0].Amount != five || d.Totals.Outstanding != five || d.Totals.Returning != 0 {
		t.Fatalf("covered refund: %v %+v %+v", err, ps, d.Totals)
	}

	// Mixed: both are paid in either order, the covered one consuming its
	// reservation and the released one minting anew, past int64.
	for _, order := range [][]uint64{{1, 2}, {2, 1}} {
		rt, d := setup()
		d.Totals.Outstanding = maxInt64 - five // forged credits took the rest
		amount := map[uint64]uint256{1: five, 2: three}
		var items []SettleItem
		for _, seq := range order {
			items = append(items, SettleItem{Seq: seq, Action: SettlePay, Amount: amount[seq]})
		}
		ps, err := settleProven(rt, "ethereum-1", items, "inc", lockOf(0))
		if err != nil || len(ps) != 2 || d.Totals.Outstanding != maxInt64+three || d.Totals.Returning != 0 || d.Totals.QueuedRefunds != 0 {
			t.Fatalf("order %v: %v %+v %+v", order, err, ps, d.Totals)
		}
		for _, seq := range order {
			if rec, _ := rt.Send(pk(seq)); rec.Payment != PayReconciled || rec.Settlement != SettlePay || rec.Reservation != 0 || rec.Refunded != amount[seq] {
				t.Fatalf("order %v: %+v", order, rec)
			}
		}
	}
}

// A settlement releases every reservation its batch holds before it pays
// (Codex round 32 #3): a refund paid ahead of a delivered return in the
// batch, with a sum past int64, settles in either order, the delivered
// return's reservation released and the refund minted whole.
func TestSettlementReleasesBeforePaying(t *testing.T) {
	const six, four = uint256(6_000_000_000_000_000_000), uint256(4_000_000_000_000_000_000)
	for _, order := range [][]uint64{{1, 2}, {2, 1}} {
		r, rt := newRoute(t)
		cfg := DenomConfig{Kind: KindMint, CapFloor: maxAmount, SupplyCap: maxAmount, Fee: 10, FeeFloor: 1, RefundCap: maxAmount}
		if err := rt.SetDenom("ibc/BIG", cfg, t0, 0, maxInt64); err != nil {
			t.Fatal(err)
		}
		d := rt.Denom("ibc/BIG")
		rt.RecordSend(sendRec(1, "ibc/BIG", KindMint, six)) // refundable; a forged success released it
		rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0)
		rt.RecordSend(sendRec(2, "ibc/BIG", KindMint, four)) // delivered, still reserving four
		d.Totals.Outstanding = maxInt64 - four
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
		amount := map[uint64]uint256{1: six, 2: 0}
		action := map[uint64]uint8{1: SettlePay, 2: SettleDelivered}
		var items []SettleItem
		for _, seq := range order {
			items = append(items, SettleItem{Seq: seq, Action: action[seq], Amount: amount[seq]})
		}
		rt.send(pk(1)).Proven = ProvenRefundable
		rt.send(pk(2)).Proven = ProvenDelivered
		ps, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(0), activeAll)
		if err != nil || len(ps) != 1 || ps[0].Amount != six || d.Totals.Returning != 0 || d.Totals.QueuedRefunds != 0 || d.Totals.Outstanding != maxInt64-four+six {
			t.Fatalf("order %v: %v %+v %+v", order, err, ps, d.Totals)
		}
	}
}

// prove records outcome on the send of seq through a trusted verifier.
func prove(t *testing.T, rt *Route, seq uint64, outcome uint8, trusted func(string, uint64) bool) {
	t.Helper()
	rec, _ := rt.Send(pk(seq))
	if err := rt.ProveOutcome(pk(seq), rec.Packet, outcome, 72, "ethereum-2", 1, trusted); err != nil {
		t.Fatal(err)
	}
}

// A refund a forged success hid gets its reservation back when its outcome
// is proven, not when its settlement runs (Ethereum review round 18): two
// such refunds settled by separate decisions never pay the first from the
// second's backing, nor does a credit in between take it. An unescrowed
// denom reserves the escrow, a minted one the supply cap; a proof voided by
// a new trust generation releases its reservation when the outcome is
// proven again.
func TestProvenRefundReservedUntilSettled(t *testing.T) {
	// Escrow: two sends of 1000, both acknowledged by a forged success; the
	// escrow holds both.
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
	rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 2_000)
	rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, 2_000)
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	prove(t, rt, 1, ProvenRefundable, activeAll)
	prove(t, rt, 2, ProvenCollision, activeAll)
	d := rt.Denom("ugnot")
	if d.Totals.ProvenOwed != 2_000 || d.Reserved() != 2_000 {
		t.Fatalf("proven owed %d reserved %d", d.Totals.ProvenOwed, d.Reserved())
	}
	// The first settlement pays 1000 of the 2000 escrowed.
	if ps, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 1_000}}, "inc", lockOf(2_000), activeAll); err != nil || len(ps) != 1 {
		t.Fatalf("first: %v %+v", err, ps)
	}
	// In between, a credit of the 1000 left finds no free escrow: swept.
	if swept, err := rt.Credit(t0, 10, 0, PacketKey("ethereum-2", 50), "ugnot", bob, 1_000, ByPacket, "", 1_000); err != nil || !swept {
		t.Fatalf("a credit took the proven refund's escrow: %v %v", swept, err)
	}
	// The second settlement still pays from the 1000 that backs it.
	if ps, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 2, Action: SettlePay, Amount: 1_000}}, "inc", lockOf(1_000), activeAll); err != nil || len(ps) != 1 {
		t.Fatalf("second: %v %+v", err, ps)
	}
	if d.Totals.ProvenOwed != 0 {
		t.Fatalf("proven owed %d", d.Totals.ProvenOwed)
	}

	// Supply: two returns of 1000 under a cap of 10000, both hidden by a
	// forged success; the cap counts their proven refunds.
	r, rt = newRoute(t)
	cfg := mintCfg()
	cfg.SupplyCap = 10_000
	rt.SetDenom("ibc/W", cfg, t0, 0, 10_000)
	w := rt.Denom("ibc/W")
	rt.RecordSend(sendRec(1, "ibc/W", KindMint, 1_000))
	rt.RecordSend(sendRec(2, "ibc/W", KindMint, 1_000))
	rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0)
	rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, 0)
	if err := rt.CheckCredit("ibc/W", 2_000); err != nil {
		t.Fatalf("setup: %v", err)
	}
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	prove(t, rt, 1, ProvenRefundable, activeAll)
	prove(t, rt, 2, ProvenRefundable, activeAll)
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 1_000}}, "inc", lockOf(0), activeAll); err != nil {
		t.Fatal(err)
	}
	// In between, no credit takes the capacity the second refund needs.
	if err := rt.CheckCredit("ibc/W", 1); err == nil {
		t.Fatalf("a credit took the second refund's supply capacity: %+v", w.Totals)
	}
	// A proof never releases a reservation, a delivery proven after a void
	// one included (Codex round 39 #1): only the settlement does.
	prove(t, rt, 2, ProvenDelivered, func(string, uint64) bool { return false })
	if w.Totals.ProvenOwed != 1_000 {
		t.Fatalf("a proof released the reservation: %d", w.Totals.ProvenOwed)
	}
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 2, Action: SettleDelivered}}, "inc", lockOf(0), activeAll); err != nil {
		t.Fatal(err)
	}
	if err := rt.CheckCredit("ibc/W", 1_000); err != nil || w.Totals.ProvenOwed != 0 {
		t.Fatalf("released capacity: %v %d", err, w.Totals.ProvenOwed)
	}
}

// A voucher return past the int64 limit is never refused for the open sends'
// total, and a refund installment comes off what its open record may still
// owe at once (Codex round 33 #2): 9e19 vouchers burned, timed out, refunded
// 1e19 a day; the refunded vouchers go back at once, with and without a
// standing refunds hold.
func TestReturnAfterPartialRefund(t *testing.T) {
	const nine, one = uint256(90_000_000_000_000_000_000), uint256(10_000_000_000_000_000_000)
	for _, hold := range []bool{false, true} {
		_, rt := newRoute(t)
		cfg := DenomConfig{Kind: KindMint, CapFloor: maxAmount, SupplyCap: maxAmount, Fee: 10, FeeFloor: 1, RefundCap: one}
		if err := rt.SetDenom("ibc/BIG", cfg, t0, 0, nine); err != nil {
			t.Fatal(err)
		}
		d := rt.Denom("ibc/BIG")
		rt.RecordSend(sendRec(1, "ibc/BIG", KindMint, nine))
		rt.Settle(t0, 1, pk(1), OutcomeTimeout, false, 0) // queued: above the refund meter
		ps, err := rt.PayRefunds(t0+Day, "ibc/BIG", 1, false, 0)
		if err != nil || len(ps) != 1 || ps[0].Amount != one {
			t.Fatalf("installment: %v %+v", err, ps)
		}
		if d.Totals.InFlight != nine-one || d.Totals.Returning != nine-one || d.Totals.Outstanding != one {
			t.Fatalf("after the installment %+v", d.Totals)
		}
		if hold {
			if ps, _ := rt.PayRefunds(t0+2*Day, "ibc/BIG", 1, true, 0); len(ps) != 0 {
				t.Fatalf("paid under a hold")
			}
		}
		// The refunded vouchers go back.
		if err := rt.RecordSend(sendRec(2, "ibc/BIG", KindMint, one)); err != nil {
			t.Fatalf("hold %v: the return refused: %v", hold, err)
		}
		if d.Totals.InFlight != nine || d.Totals.Returning != nine || d.Totals.Outstanding != 0 {
			t.Fatalf("hold %v: after the return %+v", hold, d.Totals)
		}
	}
}

// A settlement's releases are exact past int64 (Codex round 34 #1):
// rejecting queued refunds of 6e18 and 4e18 (proven delivered) while paying
// a genuine 1000 releases more than an int64 holds, and settles with the
// 1000 of escrow, in either order.
func TestSettlementReleasesBeyondInt64(t *testing.T) {
	const six, four = uint256(6_000_000_000_000_000_000), uint256(4_000_000_000_000_000_000)
	for _, order := range [][]uint64{{1, 2, 3}, {3, 2, 1}} {
		r, rt := newRoute(t)
		rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, six))
		rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, four))
		rt.RecordSend(sendRec(3, "ugnot", KindUnescrow, 1_000))
		for seq := uint64(1); seq <= 3; seq++ {
			rt.Settle(t0, 1, pk(seq), OutcomeTimeout, true, 0) // queued under a hold
		}
		d := rt.Denom("ugnot")
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
		item := map[uint64]SettleItem{1: {Seq: 1, Action: SettleReject}, 2: {Seq: 2, Action: SettleReject}, 3: {Seq: 3, Action: SettlePay, Amount: 1_000}}
		var items []SettleItem
		for _, seq := range order {
			items = append(items, item[seq])
		}
		ps, err := settleProven(rt, "ethereum-1", items, "inc", lockOf(1_000))
		if err != nil || len(ps) != 1 || ps[0].Amount != 1_000 || d.Totals.QueuedRefunds != 0 || rt.OpenSends("ethereum-1") != 0 {
			t.Fatalf("order %v: %v %+v %+v", order, err, ps, d.Totals)
		}
	}
}

// A minted denom's settlement refunds are never parked: nothing bounds the
// vouchers they mint again (the supply cap governs admission only), so two
// genuine refunds of 6e18 whose forged successes released their
// reservations are both paid at once, in either order, the supply exact
// past int64; the records settle, the route reopens, and a return then
// burns as usual.
func TestMintedSettlementRefundsNeverPark(t *testing.T) {
	const six = uint256(6_000_000_000_000_000_000)
	for _, order := range [][]uint64{{1, 2}, {2, 1}} {
		r, rt := newRoute(t)
		cfg := DenomConfig{Kind: KindMint, CapFloor: maxAmount, SupplyCap: maxAmount, Fee: 10, FeeFloor: 1, RefundCap: maxAmount}
		rt.SetDenom("ibc/BIG", cfg, t0, 0, six)
		d := rt.Denom("ibc/BIG")
		rt.RecordSend(sendRec(1, "ibc/BIG", KindMint, six))
		rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 0) // forged: released
		d.Totals.Outstanding = six                        // reused by later transfers
		rt.RecordSend(sendRec(2, "ibc/BIG", KindMint, six))
		rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, 0)
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
		var items []SettleItem
		for _, seq := range order {
			items = append(items, SettleItem{Seq: seq, Action: SettlePay, Amount: six})
		}
		ps, err := settleProven(rt, "ethereum-1", items, "inc", lockOf(0))
		if err != nil || len(ps) != 2 || d.Totals.Outstanding != 2*six || d.Totals.QueuedRefunds != 0 || d.Totals.Returning != 0 {
			t.Fatalf("order %v: %v %+v %+v", order, err, ps, d.Totals)
		}
		for _, seq := range order {
			if rec, _ := rt.Send(pk(seq)); rec.Settlement != SettlePay || rec.Payment != PayReconciled || rec.Refunded != six {
				t.Fatalf("order %v: send %d: %+v", order, seq, rec)
			}
		}
		if _, done, err := rt.Reopen(); err != nil || !done {
			t.Fatalf("order %v: reopen %v %v", order, done, err)
		}
		ret := sendRec(3, "ibc/BIG", KindMint, six)
		ret.Packet.SourceClient = "ethereum-2"
		ret.Key, ret.Commitment = PacketKey("ethereum-2", 3), types.CommitPacket(ret.Packet)
		if err := rt.RecordSend(ret); err != nil || d.Totals.Outstanding != six || d.Totals.Returning != six {
			t.Fatalf("order %v: the return: %v %+v", order, err, d.Totals)
		}
	}
}

// A replacement reserves every refund its suspect records may owe before
// any payment for the route (Ethereum review round 20): two escrowed sends
// of 100 whose forged successes released them, the escrow at 150 after a
// forged receive took 50. Until the preparation, run in bounded batches,
// has walked every record, no settlement applies; then a settlement paying
// the first refund, proven first, finds only 50 free (the second refund,
// still unproven, keeps its 100), whatever the order the proofs come in.
// With the escrow whole, the staggered proofs pay both.
func TestStaggeredProofsKeepSiblingBacking(t *testing.T) {
	setup := func() (*Route, *Denom) {
		r, rt := newRoute(t)
		rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 100))
		rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 100))
		rt.Settle(t0, 5, pk(1), OutcomeSuccess, false, 200)
		rt.Settle(t0, 5, pk(2), OutcomeSuccess, false, 200)
		if err := r.Replace("ethereum-1", "ethereum-2", 3, 1000); err != nil {
			t.Fatal(err)
		}
		return rt, rt.Denom("ugnot")
	}
	pay := func(rt *Route, seq uint64, lock uint256) error {
		_, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: seq, Action: SettlePay, Amount: 100}}, "inc", lockOf(lock), activeAll)
		return err
	}

	rt, d := setup()
	// One record a batch: the walk crosses a batch boundary.
	if n, done, _ := rt.PrepareReplacement(1); n != 1 || done {
		t.Fatalf("first batch: %d %v", n, done)
	}
	prove(t, rt, 1, ProvenRefundable, activeAll)
	if err := pay(rt, 1, 150); err == nil || !strings.Contains(err.Error(), "not prepared") {
		t.Fatalf("paid before the preparation completed: %v", err)
	}
	if n, done, _ := rt.PrepareReplacement(1); n != 1 || !done {
		t.Fatalf("second batch: %d %v", n, done)
	}
	if d.Totals.ProvenOwed != 200 {
		t.Fatalf("reserved %d", d.Totals.ProvenOwed)
	}
	// The first refund cannot take the second's backing: it would park.
	one := []SettleItem{{Seq: 1, Action: SettlePay, Amount: 100}}
	if msg := planParks(rt, one, lockOf(150), activeAll, 0, 1); msg != "" {
		t.Fatalf("the first refund against the second's backing: %s", msg)
	}
	// A proof of delivery releases nothing; the settlement applying it does,
	// in the same batch as the first refund's payment.
	prove(t, rt, 2, ProvenDelivered, activeAll)
	if msg := planParks(rt, one, lockOf(150), activeAll, 0, 1); msg != "" {
		t.Fatalf("a delivery proof released the sibling's backing: %s", msg)
	}
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 100}, {Seq: 2, Action: SettleDelivered}}, "inc", lockOf(150), activeAll); err != nil {
		t.Fatal(err)
	}

	// Both proven, settled in one batch, either order, with the escrow short
	// (150 behind 200): neither is paid out of the other's backing, both
	// park, as each would settled alone (code review r53 #1; Ethereum's
	// test_r17_1_twinHiddenRefunds_reservedBeforeAnyPayment).
	for _, order := range [][]uint64{{1, 2}, {2, 1}} {
		rt, d = setup()
		for done := false; !done; {
			_, done, _ = rt.PrepareReplacement(1)
		}
		prove(t, rt, 1, ProvenRefundable, activeAll)
		prove(t, rt, 2, ProvenRefundable, activeAll)
		items := []SettleItem{{Seq: order[0], Action: SettlePay, Amount: 100}, {Seq: order[1], Action: SettlePay, Amount: 100}}
		ps, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(150), activeAll)
		if err != nil || len(ps) != 0 || d.Totals.QueuedRefunds != 200 {
			t.Fatalf("order %v: %v %+v %d", order, err, ps, d.Totals.QueuedRefunds)
		}
		for _, seq := range order {
			if r, _ := rt.Send(pk(seq)); r.Payment != PayQueued || r.Settlement != SettlePay {
				t.Fatalf("order %v: %d not parked: %+v", order, seq, r)
			}
		}
	}
	// Backed whole (200), one batch pays both, either order.
	for _, order := range [][]uint64{{1, 2}, {2, 1}} {
		rt, d = setup()
		for done := false; !done; {
			_, done, _ = rt.PrepareReplacement(1)
		}
		prove(t, rt, 1, ProvenRefundable, activeAll)
		prove(t, rt, 2, ProvenRefundable, activeAll)
		items := []SettleItem{{Seq: order[0], Action: SettlePay, Amount: 100}, {Seq: order[1], Action: SettlePay, Amount: 100}}
		if ps, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(200), activeAll); err != nil || len(ps) != 2 || d.Totals.ProvenOwed != 0 {
			t.Fatalf("order %v whole: %v %+v", order, err, ps)
		}
	}

	// At the int64 boundary (code review r54 #1): two refunds of 2^62 owe
	// MaxInt64 + 1, which no escrow (an int64) backs: both park, in either
	// order, and nothing is paid that the token could refuse. Two of 2^62
	// and 2^62 - 1 (exactly MaxInt64) behind MaxInt64 are both paid.
	big2 := func(a1, a2 uint256) (*Route, *Denom) {
		r, rt := newRoute(t)
		rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, a1))
		rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, a2))
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
		prove(t, rt, 1, ProvenRefundable, activeAll)
		prove(t, rt, 2, ProvenRefundable, activeAll)
		return rt, rt.Denom("ugnot")
	}
	const q = uint256(1) << 62
	for _, order := range [][]uint64{{1, 2}, {2, 1}} {
		rt, d := big2(q, q)
		items := []SettleItem{{Seq: order[0], Action: SettlePay, Amount: q}, {Seq: order[1], Action: SettlePay, Amount: q}}
		ps, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(maxInt64), activeAll)
		if err != nil || len(ps) != 0 || d.Totals.QueuedRefunds != 2*q {
			t.Fatalf("order %v at the boundary: %v %+v %d", order, err, ps, d.Totals.QueuedRefunds)
		}
		rt, d = big2(q, q-1)
		amounts := map[uint64]uint256{1: q, 2: q - 1}
		items = []SettleItem{{Seq: order[0], Action: SettlePay, Amount: amounts[order[0]]}, {Seq: order[1], Action: SettlePay, Amount: amounts[order[1]]}}
		if ps, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(maxInt64), activeAll); err != nil || len(ps) != 2 {
			t.Fatalf("order %v exactly backed: %v %+v", order, err, ps)
		}
	}

	// The escrow whole: proven one after the other, both are paid.
	rt, d = setup()
	for done := false; !done; {
		_, done, _ = rt.PrepareReplacement(1)
	}
	prove(t, rt, 1, ProvenRefundable, activeAll)
	if err := pay(rt, 1, 200); err != nil {
		t.Fatal(err)
	}
	prove(t, rt, 2, ProvenRefundable, activeAll)
	if err := pay(rt, 2, 100); err != nil || d.Totals.ProvenOwed != 0 {
		t.Fatalf("%v %d", err, d.Totals.ProvenOwed)
	}
}

// The same for a minted denom: the returns' supply is reserved again by the
// preparation, so no credit takes a sibling's capacity before its proof.
func TestStaggeredProofsKeepSiblingSupply(t *testing.T) {
	r, rt := newRoute(t)
	d := rt.Denom("ibc/WETH")
	d.Totals.Outstanding = d.Config.SupplyCap
	rt.RecordSend(sendRec(1, "ibc/WETH", KindMint, 100))
	rt.RecordSend(sendRec(2, "ibc/WETH", KindMint, 100))
	rt.Settle(t0, 5, pk(1), OutcomeSuccess, false, 0)
	rt.Settle(t0, 5, pk(2), OutcomeSuccess, false, 0)
	if err := rt.CheckCredit("ibc/WETH", 200); err != nil {
		t.Fatalf("setup: %v", err)
	}
	r.Replace("ethereum-1", "ethereum-2", 3, 1000)
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 100}}, "inc", lockOf(0), activeAll); err == nil {
		t.Fatalf("settled before the preparation")
	}
	for done := false; !done; {
		_, done, _ = rt.PrepareReplacement(1)
	}
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("a credit took the suspect returns' supply")
	}
	prove(t, rt, 1, ProvenRefundable, activeAll)
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettlePay, Amount: 100}}, "inc", lockOf(0), activeAll); err != nil {
		t.Fatal(err)
	}
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("a credit took the unproven sibling's supply")
	}
	prove(t, rt, 2, ProvenDelivered, activeAll)
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("a delivery proof released the sibling's supply")
	}
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 2, Action: SettleDelivered}}, "inc", lockOf(0), activeAll); err != nil {
		t.Fatal(err)
	}
	if err := rt.CheckCredit("ibc/WETH", 100); err != nil {
		t.Fatalf("the settled delivery's supply stays reserved: %v", err)
	}
}

// A delivery proof that is voided releases nothing (Codex round 39 #1):
// two pending escrowed sends of 1000 with 1000 escrowed, both reserved by
// the preparation; A is falsely proven delivered, then its verifier's trust
// generation changes (a freeze and recovery). B, proven refundable, cannot be
// paid out of A's backing, in either settlement order, before A is proven
// again; once A is proven refundable too, the escrow is short for both and
// each is refused alone. In the honest case, a batch settling A as delivered
// pays B.
func TestVoidedDeliveryKeepsBacking(t *testing.T) {
	setup := func() *Route {
		r, rt := newRoute(t)
		rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000))
		rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 1_000))
		replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
		return rt
	}
	gen := uint64(1)
	trusted := func(_ string, g uint64) bool { return g == gen }
	proveAt := func(rt *Route, seq uint64, outcome uint8) {
		rec, _ := rt.Send(pk(seq))
		if err := rt.ProveOutcome(pk(seq), rec.Packet, outcome, 72, "ethereum-2", gen, trusted); err != nil {
			t.Fatal(err)
		}
	}
	settle := func(rt *Route, items ...SettleItem) error {
		_, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(1_000), trusted)
		return err
	}
	for _, aFirst := range []bool{true, false} {
		gen = 1
		rt := setup()
		proveAt(rt, 1, ProvenDelivered) // false
		gen = 2                         // the verifier frozen and recovered
		proveAt(rt, 2, ProvenRefundable)
		payB := SettleItem{Seq: 2, Action: SettlePay, Amount: 1_000}
		if aFirst {
			// A's void delivery proof settles nothing.
			if settle(rt, SettleItem{Seq: 1, Action: SettleDelivered}, payB) == nil {
				t.Fatalf("settled A on a void delivery proof")
			}
		} else if msg := planParks(rt, []SettleItem{payB}, lockOf(1_000), trusted, 0, 2); msg != "" {
			t.Fatalf("B against A's backing on a void delivery proof: %s", msg)
		}
		proveAt(rt, 1, ProvenRefundable)
		for _, seq := range []uint64{1, 2} {
			if msg := planParks(rt, []SettleItem{{Seq: seq, Action: SettlePay, Amount: 1_000}}, lockOf(1_000), trusted, 0, seq); msg != "" {
				t.Fatalf("A first %v: refund %d against its sibling's backing: %s", aFirst, seq, msg)
			}
		}
	}
	// Honest: A delivered, settled in the batch that pays B.
	gen = 1
	rt := setup()
	proveAt(rt, 1, ProvenDelivered)
	proveAt(rt, 2, ProvenRefundable)
	if err := settle(rt, SettleItem{Seq: 2, Action: SettlePay, Amount: 1_000}, SettleItem{Seq: 1, Action: SettleDelivered}); err != nil {
		t.Fatal(err)
	}
}

// Every move to the next retired client takes a step of the preparation's
// budget (Codex round 41 #2): many replacements of clients with no records,
// queued behind an unfinished preparation, are walked a bounded few a call,
// and the walk completes.
func TestPrepareChargesEmptyClients(t *testing.T) {
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 100))
	rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 100))
	// ethereum-1 has two records; ten empty clients follow.
	for i := 2; i <= 12; i++ {
		if err := r.Replace("ethereum-1", "ethereum-"+strconv.Itoa(i), 0, int64(1000+i)); err != nil {
			t.Fatal(err)
		}
	}
	calls := 0
	for done := false; !done; calls++ {
		before := rt.prepIdx
		_, done, _ = rt.PrepareReplacement(2)
		if rt.prepIdx-before > 2 {
			t.Fatalf("a call of budget 2 moved past %d clients", rt.prepIdx-before)
		}
		if calls > 20 {
			t.Fatalf("the preparation never completes")
		}
	}
	if !rt.Prepared() || calls < 6 {
		t.Fatalf("prepared %v after %d calls", rt.Prepared(), calls)
	}
}

// An escrowed refund the drained escrow cannot pay is parked, not refused:
// the route reopens with the forged payout accepted as a deficit, and the
// refund is paid once the escrow is whole again (Codex design round 3 #3).
func TestEscrowRefundParksThroughReopen(t *testing.T) {
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 100))
	// A forged receive pays out of the escrow the send locked.
	mustCredit(t, rt, t0, 5, "ugnot", alice, 3_000, big)
	rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, big)
	c, _ := rt.Claim(pk(5))
	if c.Paid == 0 {
		t.Fatalf("setup: %+v", c)
	}
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	items := []SettleItem{{Seq: 5, Action: SettleForgedReceive, Amount: c.Paid}, {Seq: 1, Action: SettlePay, Amount: 100}}
	ps, err := settleProven(rt, "ethereum-1", items, "inc", lockOf(0))
	r1, _ := rt.Send(pk(1))
	d := rt.Denom("ugnot")
	if err != nil || len(ps) != 0 || r1.Settlement != SettlePay || r1.Payment != PayQueued || d.Totals.QueuedRefunds != 100 {
		t.Fatalf("the refund was not parked: %v %+v %+v", err, ps, r1)
	}
	accepted, done, err := rt.Reopen()
	if err != nil || !done || accepted != c.Paid {
		t.Fatalf("reopen: %d %v %v", accepted, done, err)
	}
	if ps, _ := rt.PayRefunds(t0+2*Day, "ugnot", 1, false, 0); len(ps) != 0 {
		t.Fatalf("paid out of an empty escrow: %+v", ps)
	}
	// Recapitalized: the escrow holds the refund again.
	ps, err = rt.PayRefunds(t0+2*Day, "ugnot", 1, false, 100)
	if r1, _ = rt.Send(pk(1)); err != nil || len(ps) != 1 || ps[0].Amount != 100 || ps[0].To != r1.Sender || d.Totals.QueuedRefunds != 0 {
		t.Fatalf("the parked refund was not paid: %v %+v", err, ps)
	}
}

// The route-wide blocker check after repeated replacements (design review r4
// #2): A → B → C, each retired client with an open send. Every blocker is
// listed with its own suspect height until its records are settled, B's
// first, A's after, proven through C; then the reopening applies.
func TestReopenBlockersAcrossReplacements(t *testing.T) {
	r, rt := newRoute(t)
	rd := Reader{r: r}
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 100))
	replaceReady(r, "ethereum-1", "ethereum-2", 7, 1000)
	b := sendRec(1, "ugnot", KindUnescrow, 100)
	b.Packet.SourceClient = "ethereum-2"
	b.Commitment = types.CommitPacket(b.Packet)
	b.Key = PacketKey("ethereum-2", 1)
	if err := rt.RecordSend(b); err != nil {
		t.Fatal(err)
	}
	replaceReady(r, "ethereum-1", "ethereum-3", 1500, 2000)
	if got := rd.ReopenBlockers("ethereum-1"); strings.Join(got, ",") != "ethereum-1,ethereum-2" {
		t.Fatalf("blockers %v", got)
	}
	if h, ok := rd.SuspectFrom("ethereum-1", "ethereum-1"); !ok || h != 7 {
		t.Fatalf("A's suspect height %d %v", h, ok)
	}
	if h, ok := rd.SuspectFrom("ethereum-1", "ethereum-2"); !ok || h != 1500 {
		t.Fatalf("B's suspect height %d %v", h, ok)
	}
	if _, ok := rd.SuspectFrom("ethereum-1", "ethereum-3"); ok {
		t.Fatalf("the current client has a suspect height")
	}
	if rd.OpenSends("ethereum-1", "ethereum-2") != 1 {
		t.Fatalf("B's open sends")
	}
	rt.send(PacketKey("ethereum-2", 1)).Proven = ProvenDelivered
	if _, err := rt.SettleRecords("ethereum-2", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc-b", lockOf(big), activeAll); err != nil {
		t.Fatal(err)
	}
	if got := rd.ReopenBlockers("ethereum-1"); strings.Join(got, ",") != "ethereum-1" {
		t.Fatalf("after B's settlement: %v", got)
	}
	if _, _, err := rt.Reopen(); err == nil {
		t.Fatalf("reopened with A's record open")
	}
	rt.send(pk(1)).Proven = ProvenDelivered
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc-a", lockOf(big), activeAll); err != nil {
		t.Fatal(err)
	}
	if got := rd.ReopenBlockers("ethereum-1"); len(got) != 0 {
		t.Fatalf("after A's settlement: %v", got)
	}
	if _, done, err := rt.Reopen(); err != nil || !done {
		t.Fatalf("reopen: %v", err)
	}
}

// A settled record takes no proof, preparation or late outcome (Ethereum
// design review cross-check): a settlement is final, so a reservation made
// after it could never be released. Settle, void the proofs (a new trust
// generation), then prove again: refused, and nothing reserved changes.
func TestSettledRecordTakesNoProof(t *testing.T) {
	r, rt := newRoute(t)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000)) // a forged success hid its refund
	rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 1_000)) // delivered
	rt.RecordSend(sendRec(3, "ugnot", KindUnescrow, 1_000)) // still pending at its settlement
	rt.Settle(t0, 1, pk(1), OutcomeSuccess, false, 3_000)
	rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, 3_000)
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	gen := uint64(1)
	current := func(_ string, g uint64) bool { return g == gen }
	prove(t, rt, 1, ProvenRefundable, current)
	prove(t, rt, 2, ProvenDelivered, current)
	prove(t, rt, 3, ProvenDelivered, current)
	items := []SettleItem{{Seq: 1, Action: SettlePay, Amount: 1_000}, {Seq: 2, Action: SettleDelivered}, {Seq: 3, Action: SettleDelivered}}
	if _, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(3_000), current); err != nil {
		t.Fatal(err)
	}
	d := rt.Denom("ugnot")
	owed, reserved, queued := d.Totals.ProvenOwed, d.Reserved(), d.Totals.QueuedRefunds
	if owed != 0 {
		t.Fatalf("proven owed %d after the settlement", owed)
	}
	gen++ // the verifier is recovered: every earlier proof is void
	for _, seq := range []uint64{1, 2, 3} {
		before, _ := rt.Send(pk(seq))
		for _, outcome := range []uint8{ProvenRefundable, ProvenCollision, ProvenDelivered} {
			err := rt.ProveOutcome(pk(seq), before.Packet, outcome, 90, "ethereum-2", gen, current)
			if err == nil || !strings.Contains(err.Error(), "settled already") {
				t.Fatalf("send %d: proved outcome %d after its settlement: %v", seq, outcome, err)
			}
		}
		after, _ := rt.Send(pk(seq))
		if after.Proven != before.Proven || after.ProvenAt != before.ProvenAt || after.ProvenGen != before.ProvenGen || after.ProvenReserve != 0 {
			t.Fatalf("send %d: a refused proof changed the record: %+v -> %+v", seq, before, after)
		}
	}
	// A late acknowledgement of the pending one moves nothing either, and a
	// preparation walk reserves nothing for a settled record.
	if paid, err := rt.Settle(t0, 2, pk(3), OutcomeTimeout, false, 3_000); err != nil || paid != 0 {
		t.Fatalf("late outcome of a settled send: %d %v", paid, err)
	}
	rt.PrepareReplacement(MaxKeys)
	if d.Totals.ProvenOwed != owed || d.Reserved() != reserved || d.Totals.QueuedRefunds != queued {
		t.Fatalf("reservations changed after the settlement: %+v", d.Totals)
	}
}
