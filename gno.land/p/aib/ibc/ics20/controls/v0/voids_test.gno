package controls

import (
	"errors"
	"strconv"
	"strings"
	"testing"
)

func setupClaims(t *testing.T) (*Route, int64) {
	_, rt := newRoute(t)
	lock := int64(100_000) // cap 10000, a recipient 2500 a day
	mustCredit(t, rt, t0, 1, "ugnot", alice, 50_000, lock)
	mustCredit(t, rt, t0, 2, "ugnot", bob, 3_000, lock)
	mustCredit(t, rt, t0, 3, "ugnot", carol, 10, lock) // swept: below the fee
	// Pay part of claim 1.
	if ps, _ := rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, lock); len(ps) != 1 || ps[0].Key != pk(1) {
		t.Fatalf("setup: %+v", ps)
	}
	return rt, lock
}

func TestVoidWithheldAndRestore(t *testing.T) {
	rt, lock := setupClaims(t)
	d := rt.Denom("ugnot")
	before := d.Totals
	c1, _ := rt.Claim(pk(1))
	if err := rt.Void([]string{pk(1), pk(2)}, false, "inc"); err != nil {
		t.Fatal(err)
	}
	if d.Totals.Owed != 0 || d.Totals.Withheld != before.Owed || d.Totals.Lost != 0 {
		t.Fatalf("withheld totals %+v", d.Totals)
	}
	// Withheld claims leave the queue: claims pay nothing.
	if ps, _ := rt.PayClaims(t0+5*Day, 0, t0, "ugnot", 20, lock); len(ps) != 0 {
		t.Fatalf("paid a withheld claim: %+v", ps)
	}
	// Withheld claims still reserve the escrow.
	if d.Reserved() != before.Owed {
		t.Fatalf("reserved %d", d.Reserved())
	}
	if err := rt.Void([]string{pk(1)}, false, "inc"); err == nil {
		t.Fatalf("withheld twice")
	}
	if err := rt.Restore([]string{pk(1), pk(2)}, t0+5*Day, 0); err != nil {
		t.Fatal(err)
	}
	if d.Totals != before {
		t.Fatalf("restore is not the inverse:\n%+v\n%+v", d.Totals, before)
	}
	c, _ := rt.Claim(pk(1))
	if c.State != Open || c.Seq != c1.Seq || c.Paid != c1.Paid {
		t.Fatalf("%+v", c)
	}
	checkClaimTotals(t, rt, "ugnot")
}

func TestVoidForgedBooksPaidPartAsLoss(t *testing.T) {
	rt, _ := setupClaims(t)
	d := rt.Denom("ugnot")
	c1, _ := rt.Claim(pk(1))
	if c1.Paid == 0 {
		t.Fatalf("setup paid nothing")
	}
	before := d.Totals
	if err := rt.Void([]string{pk(1), pk(3)}, true, "inc-7"); err != nil {
		t.Fatal(err)
	}
	if d.Totals.Lost != c1.Paid || d.Totals.Owed != before.Owed-c1.Remaining() || d.Totals.Swept != 0 {
		t.Fatalf("forged totals %+v", d.Totals)
	}
	if d.Totals.Unrecovered() != c1.Paid || rt.Unrecovered() != c1.Paid {
		t.Fatalf("unrecovered %d", d.Totals.Unrecovered())
	}
	lj := Reader{}.LossesJSON("x", "") // an invalid reader reads empty
	if lj != emptyPage {
		t.Fatalf("%s", lj)
	}
	// A forged void and a voided sweep entry are final.
	after := d.Totals
	for _, k := range []string{pk(1), pk(3)} {
		if err := rt.Restore([]string{k}, t0+2*Day, 0); err == nil {
			t.Fatalf("restored the forged void of %s", k)
		}
	}
	if d.Totals != after {
		t.Fatalf("a refused restore changed state")
	}
}

// A withheld claim can be re-voided as forged; a paid claim only as forged;
// nothing else is voidable, and a bad key list changes nothing.
func TestVoidableRules(t *testing.T) {
	rt, lock := setupClaims(t)
	// Pay claim 2 in full.
	for day := int64(2); day < 8; day++ {
		rt.PayClaims(t0+day*Day, 0, t0, "ugnot", 20, lock)
	}
	c2, _ := rt.Claim(pk(2))
	if c2.State != Done {
		t.Fatalf("setup: %+v", c2)
	}
	if rt.Voidable(pk(2), false) || !rt.Voidable(pk(2), true) {
		t.Fatalf("a done claim is voidable as forged only")
	}
	if rt.Voidable(pk(3), false) || !rt.Voidable(pk(3), true) {
		t.Fatalf("a sweep entry is voidable as forged only")
	}
	if rt.Voidable(pk(99), true) {
		t.Fatalf("an unknown key is voidable")
	}
	d := rt.Denom("ugnot")
	before := d.Totals
	if err := rt.Void([]string{pk(1), pk(2)}, false, "inc"); err == nil {
		t.Fatalf("withheld a done claim")
	}
	if err := rt.Void([]string{pk(1), pk(1)}, true, "inc"); err == nil {
		t.Fatalf("a key named twice")
	}
	if err := rt.Void([]string{"nope"}, true, "inc"); err == nil {
		t.Fatalf("a bad key")
	}
	if err := rt.Void(nil, true, "inc"); err == nil {
		t.Fatalf("no key")
	}
	if d.Totals != before {
		t.Fatalf("a refused void changed state")
	}
	// Withheld then forged.
	if err := rt.Void([]string{pk(1)}, false, "inc"); err != nil {
		t.Fatal(err)
	}
	if err := rt.Void([]string{pk(1), pk(2)}, true, "inc"); err != nil {
		t.Fatal(err)
	}
	c1, _ := rt.Claim(pk(1))
	if d.Totals.Withheld != 0 || d.Totals.Lost != c1.Paid+c2.Paid {
		t.Fatalf("%+v", d.Totals)
	}
	if err := rt.Restore([]string{pk(99)}, t0, 0); err == nil {
		t.Fatalf("restored an unknown key")
	}
	keys := make([]string, MaxKeys+1)
	for i := range keys {
		keys[i] = pk(uint64(i + 100))
	}
	if err := rt.Void(keys, true, "inc"); err == nil || !strings.Contains(err.Error(), "more than") {
		t.Fatalf("too many keys: %v", err)
	}
}

func TestCreditByVote(t *testing.T) {
	rt, lock := setupClaims(t)
	d := rt.Denom("ugnot")
	// Packet 4 is swept above the free lock; a vote credits it once the lock
	// allows, replacing the entry, never above what the packet carried.
	if !mustCredit(t, rt, t0, 4, "ugnot", carol, lock, lock) {
		t.Fatalf("setup: not swept")
	}
	swept := d.Totals.Swept
	if err := rt.CreditByVote(t0, 20, 0, pk(4), "ugnot", carol, 10, 2*lock); err == nil {
		t.Fatalf("credited below the fee")
	}
	if err := rt.CreditByVote(t0, 20, 0, pk(4), "ugnot", carol, lock+1, 3*lock); err == nil {
		t.Fatalf("credited more than the packet carried")
	}
	// Never less either: the rest would vanish from the accounting (Codex
	// round 3 #2).
	if err := rt.CreditByVote(t0, 20, 0, pk(4), "ugnot", carol, lock-100, 3*lock); err == nil {
		t.Fatalf("credited part of the sweep entry")
	}
	if err := rt.CreditByVote(t0, 20, 0, pk(4), "ugnot", carol, lock, lock); err == nil {
		t.Fatalf("credited above the free lock")
	}
	if err := rt.CreditByVote(t0, 20, 0, pk(4), "ugnot", carol, lock, 2*lock); err != nil {
		t.Fatal(err)
	}
	e, _ := rt.Sweep(pk(4))
	c, _ := rt.Claim(pk(4))
	if !e.Paid || c.By != ByVote || c.Amount != lock || d.Totals.Swept != swept-lock {
		t.Fatalf("%+v %+v %+v", e, c, d.Totals)
	}
	// Deduplicated against every claim and payment of the packet.
	if err := rt.CreditByVote(t0, 20, 0, pk(1), "ugnot", alice, 50, 2*lock); err == nil {
		t.Fatalf("credited a packet with a claim")
	}
	if err := rt.CreditByVote(t0, 20, 0, pk(4), "ugnot", alice, 50, 2*lock); err == nil {
		t.Fatalf("credited a packet twice")
	}
	checkClaimTotals(t, rt, "ugnot")
}

// A receive these controls never booked was paid at once by impl/v0 (it
// predates the activation): a credit by vote of it would pay it twice
// (Codex review #2).
func TestCreditByVoteOnlyAfterActivation(t *testing.T) {
	rt, lock := setupClaims(t)
	if err := rt.CreditByVote(t0, 20, 0, pk(50), "ugnot", alice, 100, lock); err == nil {
		t.Fatalf("credited a packet the controls never booked")
	}
	// A sweep entry from before the activation height is not one either.
	r := NewRegistry()
	late, _ := r.Enroll("ethereum-1", collector, t0, 50)
	late.SetDenom("ugnot", gnot(), t0, 0, 0)
	late.Credit(t0, 10, 0, pk(1), "ugnot", alice, 100, ByPacket, "bridge realm", lock) // swept at height 10
	if err := late.CreditByVote(t0, 60, 0, pk(1), "ugnot", alice, 100, lock); err == nil || !strings.Contains(err.Error(), "not received under") {
		t.Fatalf("credited a receive from before the activation: %v", err)
	}
}

func TestPaySweeps(t *testing.T) {
	rt, lock := setupClaims(t)
	mustCredit(t, rt, t0, 4, "ugnot", "g1notreally", 15, lock) // swept below the fee
	d := rt.Denom("ugnot")
	if _, err := rt.PaySweeps([]string{pk(3), pk(4)}, collector, 20); err == nil {
		t.Fatalf("paid 25 from a lock of 20")
	}
	ps, err := rt.PaySweeps([]string{pk(3), pk(4)}, collector, lock)
	if err != nil || len(ps) != 2 || ps[0].To != collector || ps[0].Amount+ps[1].Amount != 25 {
		t.Fatalf("%+v %v", ps, err)
	}
	if d.Totals.Swept != 0 || d.Totals.SweepPaid != 25 {
		t.Fatalf("%+v", d.Totals)
	}
	if _, err := rt.PaySweeps([]string{pk(3)}, collector, lock); err == nil {
		t.Fatalf("paid twice")
	}
	if _, err := rt.PaySweeps([]string{pk(1)}, collector, lock); err == nil {
		t.Fatalf("paid a claim as a sweep")
	}
}

// The loss ledger: decided losses, recapitalization, reductions and accepted
// deficits, which only ever bring the unrecovered total down to zero.
func TestLossLedger(t *testing.T) {
	rt, _ := setupClaims(t)
	d := rt.Denom("ugnot")
	if err := rt.RecordLoss(pk(10), "ugnot", 1_000, ChainGno, "inc", "forged-delivery"); err != nil {
		t.Fatal(err)
	}
	if err := rt.RecordLoss(pk(10), "ugnot", 1_000, ChainGno, "inc", "forged-delivery"); err == nil {
		t.Fatalf("recorded twice")
	}
	if err := rt.RecordLoss(pk(11), "ugnot", 1, "mars", "inc", "x"); err == nil {
		t.Fatalf("bad chain")
	}
	if err := rt.RecordLoss(pk(11), "ugnot", 1, ChainGno, "", "x"); err == nil {
		t.Fatalf("no incident")
	}
	if err := rt.RecordLoss(pk(11), "ugnot", 1, ChainGno, "inc", "forged payout"); err == nil {
		t.Fatalf("forged payouts are recorded by voids only")
	}
	if d.Totals.Unrecovered() != 1_000 {
		t.Fatalf("%d", d.Totals.Unrecovered())
	}
	// Recapitalization: authorized up to the unrecovered, paid exactly.
	if _, err := rt.AuthorizeRecap("ugnot", 1_001, "inc"); err == nil {
		t.Fatalf("authorized more than lost")
	}
	id, err := rt.AuthorizeRecap("ugnot", 600, "inc")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rt.AuthorizeRecap("ugnot", 401, "inc"); err == nil {
		t.Fatalf("authorized more than the losses not yet authorized")
	}
	if err := rt.Recapitalize(id, "ugnot", 599, alice); err == nil {
		t.Fatalf("paid the wrong amount")
	}
	if err := rt.Recapitalize(id, "ugnot", 600, alice); err != nil {
		t.Fatal(err)
	}
	if err := rt.Recapitalize(id, "ugnot", 600, alice); err == nil {
		t.Fatalf("paid twice")
	}
	if d.Totals.Unrecovered() != 400 {
		t.Fatalf("%d", d.Totals.Unrecovered())
	}
	// A reduction cuts an open claim and the unrecovered losses alike.
	c2, _ := rt.Claim(pk(2))
	owed := d.Totals.Owed
	if err := rt.Reduce(pk(2), 401, "inc"); err == nil {
		t.Fatalf("reduced more than unrecovered")
	}
	if err := rt.Reduce(pk(2), 300, "inc"); err != nil {
		t.Fatal(err)
	}
	c2b, _ := rt.Claim(pk(2))
	if c2b.Amount != c2.Amount-300 || c2b.Reduced != 300 || d.Totals.Owed != owed-300 || d.Totals.Unrecovered() != 100 {
		t.Fatalf("%+v %+v", c2b, d.Totals)
	}
	// An accepted deficit closes the rest; nothing goes below zero.
	if err := rt.Accept("ugnot", 101, "inc"); err == nil {
		t.Fatalf("accepted more than unrecovered")
	}
	if err := rt.Accept("ugnot", 100, "inc"); err != nil {
		t.Fatal(err)
	}
	// Accepting restores neither backing nor liabilities: the loss stays in
	// the supply identity's unrecovered term, and only stops waiting for a
	// restoring decision (Codex review #5).
	if d.Totals.Unrecovered() != 100 || rt.Unrecovered() != 100 || d.Totals.Unresolved() != 0 || rt.Unresolved() != 0 {
		t.Fatalf("%+v", d.Totals)
	}
	if err := rt.Accept("ugnot", 1, "inc"); err == nil {
		t.Fatalf("accepted the same loss twice")
	}
	if _, err := rt.AuthorizeRecap("ibc/WETH", 1, "inc"); err == nil {
		t.Fatalf("recapitalized a minted denom")
	}
	checkClaimTotals(t, rt, "ugnot")
}

// A reduction of a withheld claim lowers the withheld term.
func TestReduceWithheld(t *testing.T) {
	rt, _ := setupClaims(t)
	d := rt.Denom("ugnot")
	rt.RecordLoss(pk(10), "ugnot", 5_000, ChainGno, "inc", "forged delivery")
	rt.Void([]string{pk(2)}, false, "inc")
	if err := rt.Reduce(pk(2), 3_000, "inc"); err != nil {
		t.Fatal(err)
	}
	c, _ := rt.Claim(pk(2))
	if d.Totals.Withheld != 0 || c.Remaining() != 0 || c.State != Withheld {
		t.Fatalf("%+v %+v", c, d.Totals)
	}
}

// An unpaid owed sweep entry is reduced like a claim: partly, never beyond
// its amount, and to nothing (Codex round 2 #5).
func TestReduceSweep(t *testing.T) {
	rt, _ := setupClaims(t)
	d := rt.Denom("ugnot")
	rt.Credit(t0, 10, 0, pk(20), "ugnot", alice, 500, ByPacket, "bridge realm", big)
	rt.RecordLoss(pk(30), "ugnot", 1_000, ChainGno, "inc", "collision")
	swept := d.Totals.Swept
	if err := rt.Reduce(pk(20), 501, "inc"); err == nil {
		t.Fatalf("reduced a sweep entry beyond its amount")
	}
	if err := rt.Reduce(pk(20), 100, "inc"); err != nil {
		t.Fatal(err)
	}
	e, _ := rt.Sweep(pk(20))
	if e.Amount != 400 || e.Reduced != 100 || d.Totals.Swept != swept-100 || d.Totals.Unrecovered() != 900 || rt.Incident("ugnot", "inc").Reduced != 100 {
		t.Fatalf("%+v %+v", e, d.Totals)
	}
	if err := rt.Reduce(pk(20), 400, "inc"); err != nil {
		t.Fatal(err)
	}
	e, _ = rt.Sweep(pk(20))
	if !e.Paid || e.Amount != 0 || d.Totals.Swept != swept-500 {
		t.Fatalf("%+v", e)
	}
	if err := rt.Reduce(pk(20), 1, "inc"); err == nil {
		t.Fatalf("reduced a closed sweep entry")
	}
	if err := rt.Reduce(pk(3), 1, "inc"); err != nil { // the live sweep entry below the fee
		t.Fatal(err)
	}
}

func TestRegistryReplace(t *testing.T) {
	r, rt := newRoute(t)
	if err := replaceReady(r, "ethereum-1", "ethereum-1", 0, 1000); err == nil {
		t.Fatalf("replaced with itself")
	}
	if err := replaceReady(r, "ethereum-9", "ethereum-2", 0, 1000); err == nil {
		t.Fatalf("replaced an unknown route")
	}
	if err := replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000); err != nil {
		t.Fatal(err)
	}
	if r.RouteOf("ethereum-2") != rt || r.RouteOf("ethereum-1") != nil || r.RetiredRouteOf("ethereum-1") != "ethereum-1" {
		t.Fatalf("aliases")
	}
	if rt.Client != "ethereum-2" || len(rt.Replaced) != 1 || rt.Replaced[0] != "ethereum-1" {
		t.Fatalf("%+v", rt)
	}
	// The route key stays; the state moves in constant work.
	if r.Route("ethereum-1") != rt {
		t.Fatalf("route key")
	}
	// A retired or current client cannot be enrolled or re-used.
	if _, err := r.Enroll("ethereum-2", collector, t0, 1); err == nil {
		t.Fatalf("enrolled a route's client")
	}
	if err := replaceReady(r, "ethereum-1", "ethereum-1", 0, 1000); err == nil {
		t.Fatalf("re-used a retired client")
	}
	// The route's current client is replaced while the route is still
	// closed from the previous replacement (Codex round 13 #2).
	if err := replaceReady(r, "ethereum-1", "ethereum-3", 0, 2000); err != nil {
		t.Fatal(err)
	}
	if len(rt.Replaced) != 2 || r.RetiredRouteOf("ethereum-2") != "ethereum-1" {
		t.Fatalf("%+v", rt.Replaced)
	}
	// The second replacement's suspect interval starts no earlier than the
	// first replacement, when ethereum-2 became current.
	if v := rt.suspect.Get("ethereum-2"); v.(int64) != 1000 {
		t.Fatalf("suspect from %d", v)
	}
	// A retired client id is final: never migrated back to.
	if err := replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000); err == nil {
		t.Fatalf("migrated back to a retired client")
	}
}

func TestRefusedRecipients(t *testing.T) {
	_, rt := newRoute(t)
	rt.Refuse([]string{"0xAbC0000000000000000000000000000000000001"})
	if !rt.IsRefused("0xabc0000000000000000000000000000000000001") || !rt.IsRefused("0XABC0000000000000000000000000000000000001") {
		t.Fatalf("case")
	}
	rt.Unrefuse([]string{"0xabc0000000000000000000000000000000000001"})
	if rt.IsRefused("0xabc0000000000000000000000000000000000001") || len(rt.Refused()) != 0 {
		t.Fatalf("unrefuse")
	}
}

// The bridge contracts are protected once, never unrefused, and each voucher
// token a denom names joins them (Codex round 6 #5).
func TestProtectedRecipients(t *testing.T) {
	_, rt := newRoute(t)
	const router, ics20, admin = "0x00000000000000000000000000000000000b0001", "0x00000000000000000000000000000000000b0002", "0x00000000000000000000000000000000000b0003"
	if rt.Bridged() {
		t.Fatalf("bridged before Protect")
	}
	if rt.Protect(router, router, admin) == nil || rt.Protect(router, ics20, "0x0000000000000000000000000000000000000000") == nil ||
		rt.Protect(router, ics20, "nope") == nil {
		t.Fatalf("accepted a bad bridge")
	}
	if err := rt.Protect(router, ics20, admin); err != nil {
		t.Fatal(err)
	}
	if !rt.Bridged() || rt.Protect(router, ics20, admin) == nil {
		t.Fatalf("Protect is once")
	}
	rt.Unrefuse([]string{router})
	if !rt.IsRefused(router) || !rt.IsRefused("0x00000000000000000000000000000000000B0003") {
		t.Fatalf("a protected contract was lifted")
	}
	c := gnot()
	c.Remote = "0x0000000000000000000000000000000000c0ffef"
	if err := rt.SetDenom("ufoo", c, t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if !rt.IsRefused(c.Remote) || len(rt.Protected()) != 3+boolInt(gnot().Remote != "")+1 {
		t.Fatalf("voucher token not protected: %v", rt.Protected())
	}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func TestCodecRoundTrip(t *testing.T) {
	p := Params{
		Route: "ethereum-1", Denom: "ugnot", Key: pk(3), Client: "ethereum-2", Chain: ChainGno, Incident: "inc", Cause: "c",
		To: alice, Keys: []string{pk(1), pk(2)}, Forged: true, Amount: 42, Config: gnot(),
		Items: []SettleItem{{Seq: 7, Action: SettlePay, Amount: 5}, {Seq: 9, Action: SettleDelivered}},
	}
	got, err := DecodeParams(p.Encode())
	if err != nil {
		t.Fatal(err)
	}
	if got.Route != p.Route || got.Denom != p.Denom || got.Key != p.Key || got.Client != p.Client || got.Chain != p.Chain ||
		got.Incident != p.Incident || got.Cause != p.Cause || got.To != p.To || len(got.Keys) != 2 || got.Keys[1] != pk(2) ||
		!got.Forged || got.Amount != 42 || got.Config != p.Config || len(got.Items) != 2 || got.Items[0] != p.Items[0] || got.Items[1] != p.Items[1] {
		t.Fatalf("%+v", got)
	}
	if _, err := DecodeParams(append(p.Encode(), 0)); err == nil {
		t.Fatalf("trailing byte")
	}
	bz := p.Encode()
	if _, err := DecodeParams(bz[:len(bz)-1]); err == nil {
		t.Fatalf("truncated")
	}
	many := Params{Keys: make([]string, MaxKeys+1)}
	if _, err := DecodeParams(many.Encode()); err == nil {
		t.Fatalf("too many keys")
	}
	manyItems := Params{Items: make([]SettleItem, MaxKeys+1)}
	if _, err := DecodeParams(manyItems.Encode()); err == nil {
		t.Fatalf("too many items")
	}
	if _, err := DecodeParams(Params{}.Encode()); err != nil {
		t.Fatalf("empty params: %v", err)
	}
}

func TestReaderJSON(t *testing.T) {
	r, rt := newRoute(t)
	mustCredit(t, rt, t0, 1, "ugnot", alice, 1_000, 100_000)
	rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 500))
	rd := r.ReadOnly().(Reader)
	if !rd.Valid() || rd.RouteOf("ethereum-1") != "ethereum-1" || rd.Client("ethereum-1") != "ethereum-1" {
		t.Fatalf("reader")
	}
	js := rd.RouteJSON("ethereum-1")
	for _, want := range []string{`"route":"ethereum-1"`, `"denom":"ugnot"`, `"kind":"unescrow"`, `"owed":1000`, `"sent":500`, `"fee_collector":"` + string(collector) + `"`} {
		if !strings.Contains(js, want) {
			t.Fatalf("route json lacks %s: %s", want, js)
		}
	}
	if rd.RouteJSON("nope") != "null" {
		t.Fatalf("unknown route")
	}
	if !strings.Contains(rd.ClaimsJSON("ethereum-1", ""), `"state":"open"`) {
		t.Fatalf("claims json")
	}
	sj := rd.SendsJSON("ethereum-1", "")
	if !strings.Contains(sj, `"value":"010203"`) || !strings.Contains(sj, `"timeout_timestamp":99`) {
		t.Fatalf("sends json %s", sj)
	}
	if c, ok := rd.DenomConfig("ethereum-1", "ugnot"); !ok || c != gnot() {
		t.Fatalf("config")
	}
	if rd.RoutesJSON() == "[]" {
		t.Fatalf("routes json")
	}
	// The JSON escapes what the counterparty wrote, and nothing of it is
	// active in Markdown (Codex round 6 #6).
	u := "\\" + "u"
	mustCredit(t, rt, t0, 3, "ugnot", `g1"x`, 1, 100_000) // swept: below the fee
	if !strings.Contains(rd.SweepsJSON("ethereum-1", ""), `"to":"g1`+u+`0022x"`) {
		t.Fatalf("escaping: %s", rd.SweepsJSON("ethereum-1", ""))
	}
	mustCredit(t, rt, t0, 4, "ugnot", "[claim](https://attacker.example)<b>", 1, 100_000)
	sweeps := rd.SweepsJSON("ethereum-1", "")
	if !strings.Contains(sweeps, `"to":"`+u+`005bclaim`+u+`005d`+u+`0028https://attacker.example`+u+`0029`+u+`003cb`+u+`003e"`) {
		t.Fatalf("markdown in the JSON: %s", sweeps)
	}
}

// A forged void whose loss was since accepted (or recapitalized, or reduced)
// cannot be restored: the surplus would hide the next real loss.
func TestRestoreOnlyWithheld(t *testing.T) {
	rt, _ := setupClaims(t)
	rt.Void([]string{pk(1)}, true, "inc")
	if err := rt.Restore([]string{pk(1)}, t0+2*Day, 0); err == nil || !strings.Contains(err.Error(), "no withheld claim") {
		t.Fatalf("restored a forged void: %v", err)
	}
	c, _ := rt.Claim(pk(1))
	if c.State != Forged {
		t.Fatalf("%+v", c)
	}
}

// Restoring a forged void of a minted claim after another credit took its
// supply would book both (Codex review #9): voided claims are restored only
// from withheld, whose remainder stays counted against the cap meanwhile.
func TestRestoreNeverOverbooksSupply(t *testing.T) {
	_, rt := newRoute(t)
	d := rt.Denom("ibc/WETH")
	supplyCap := d.Config.SupplyCap
	mustCredit(t, rt, t0, 1, "ibc/WETH", alice, supplyCap, 0)
	// Forged: the remainder is released, another credit takes the supply.
	if err := rt.Void([]string{pk(1)}, true, "inc"); err != nil {
		t.Fatal(err)
	}
	mustCredit(t, rt, t0, 2, "ibc/WETH", bob, supplyCap, 0)
	if err := rt.Restore([]string{pk(1)}, t0, 0); err == nil {
		t.Fatalf("restored a forged mint claim past the supply cap")
	}
	// Withheld: the remainder stays booked, so no other credit takes it.
	if err := rt.Void([]string{pk(2)}, false, "inc"); err != nil {
		t.Fatal(err)
	}
	if err := rt.CheckCredit("ibc/WETH", 1); err == nil {
		t.Fatalf("a withheld remainder freed the supply")
	}
	if err := rt.Restore([]string{pk(2)}, t0, 0); err != nil {
		t.Fatal(err)
	}
	if b := d.Totals.Owed + d.Totals.Withheld + d.Totals.Outstanding; b != supplyCap {
		t.Fatalf("booked %d of a cap of %d", b, supplyCap)
	}
}

// An authorized recapitalization holds its part of the incident's losses
// from other authorizations; a later alternative resolution (a reduction, an
// accepted deficit) supersedes it, revoking it, and a revoked or stale
// authorization is never paid (Codex review #6, round 2 #6).
func TestRecapAuthorizationBoundToIncident(t *testing.T) {
	rt, _ := setupClaims(t)
	d := rt.Denom("ugnot")
	if err := rt.RecordLoss(pk(10), "ugnot", 100, ChainGno, "inc-a", "forged delivery"); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.AuthorizeRecap("ugnot", 100, "inc-b"); err == nil {
		t.Fatalf("authorized against an incident without losses")
	}
	id, err := rt.AuthorizeRecap("ugnot", 100, "inc-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rt.AuthorizeRecap("ugnot", 1, "inc-a"); err == nil {
		t.Fatalf("authorized the same loss twice")
	}
	// An accepted deficit restores no backing, so it supersedes no
	// recapitalization (Codex round 13 #1): the authorization stands and
	// its funding recovers the accepted loss.
	if err := rt.Accept("ugnot", 101, "inc-a"); err == nil {
		t.Fatalf("accepted more than the loss")
	}
	if err := rt.Accept("ugnot", 100, "inc-a"); err != nil {
		t.Fatal(err)
	}
	if r, _ := rt.Recap(id); r.Revoked {
		t.Fatalf("an accepted deficit revoked the authorization")
	}
	if err := rt.Recapitalize(id, "ugnot", 100, alice); err != nil {
		t.Fatal(err)
	}
	if d.Totals.Unresolved() != 0 || d.Totals.Unrecovered() != 0 || d.Totals.Recapitalized != 100 {
		t.Fatalf("%+v", d.Totals)
	}
	// A governed revocation frees an authorization's part for a reduction.
	rt.RecordLoss(pk(11), "ugnot", 50, ChainGno, "inc-c", "forged delivery")
	id2, _ := rt.AuthorizeRecap("ugnot", 50, "inc-c")
	if err := rt.RevokeRecap(id2); err != nil {
		t.Fatal(err)
	}
	if err := rt.RevokeRecap(id2); err == nil {
		t.Fatalf("revoked twice")
	}
	if err := rt.Reduce(pk(2), 50, "inc-c"); err != nil {
		t.Fatal(err)
	}
	if err := rt.Recapitalize(id2, "ugnot", 50, alice); err == nil {
		t.Fatalf("paid a revoked authorization")
	}
	// A reduction of part of a loss revokes only what conflicts.
	rt.RecordLoss(pk(12), "ugnot", 80, ChainGno, "inc-d", "forged delivery")
	keep, _ := rt.AuthorizeRecap("ugnot", 30, "inc-d")
	drop, _ := rt.AuthorizeRecap("ugnot", 50, "inc-d")
	if err := rt.Reduce(pk(2), 40, "inc-d"); err != nil {
		t.Fatal(err)
	}
	if r, _ := rt.Recap(drop); !r.Revoked {
		t.Fatalf("the conflicting authorization stands")
	}
	if err := rt.Recapitalize(keep, "ugnot", 30, alice); err != nil {
		t.Fatal(err)
	}
}

// A packet whose asynchronous acknowledgement is unwritten is credited once,
// within what it carried and the supply cap (Codex review #14).
func TestCreditPending(t *testing.T) {
	rt, lock := setupClaims(t)
	if err := rt.CreditPending(t0, 20, 0, pk(1), "ugnot", alice, 100, 100, lock); err == nil {
		t.Fatalf("credited a packet with a claim")
	}
	if err := rt.CreditPending(t0, 20, 0, pk(3), "ugnot", alice, 100, 100, lock); err == nil {
		t.Fatalf("credited a packet with a sweep entry")
	}
	if err := rt.CreditPending(t0, 20, 0, pk(60), "ugnot", alice, 101, 100, lock); err == nil {
		t.Fatalf("credited more than the packet carried")
	}
	if err := rt.CreditPending(t0, 20, 0, pk(60), "ugnot", alice, 100, 100, lock); err != nil {
		t.Fatal(err)
	}
	if err := rt.CreditPending(t0, 20, 0, pk(60), "ugnot", alice, 100, 100, lock); err == nil {
		t.Fatalf("credited twice")
	}
	d := rt.Denom("ibc/WETH")
	d.Totals.Outstanding = d.Config.SupplyCap - 50
	if err := rt.CreditPending(t0, 20, 0, pk(61), "ibc/WETH", alice, 51, 51, 0); err == nil {
		t.Fatalf("credited past the supply cap")
	}
	if err := rt.CreditPending(t0, 20, 0, pk(61), "ibc/WETH", alice, 50, 51, 0); err == nil {
		t.Fatalf("credited part of what the packet carried")
	}
	if err := rt.CreditPending(t0, 20, 0, pk(61), "ibc/WETH", alice, 50, 50, 0); err != nil {
		t.Fatal(err)
	}
	checkClaimTotals(t, rt, "ugnot")
}

// A replacement closes the route; a governed reopening is refused while a
// send record of the retired client is open, and records every loss not
// recapitalized or reduced as an accepted deficit (Codex review #3, ADR
// pr6375 §5.4 kind 13).
func TestReplaceClosesUntilReopened(t *testing.T) {
	r, rt := newRoute(t)
	if rt.IsClosed() {
		t.Fatalf("closed at enrolment")
	}
	if _, _, err := rt.Reopen(); err == nil {
		t.Fatalf("reopened an open route")
	}
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000)) // in flight
	rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, big) // closed
	if err := replaceReady(r, "ethereum-1", "ethereum-2", 2, 1000); err != nil {
		t.Fatal(err)
	}
	if !rt.IsClosed() || !(Reader{r: r}).Closed("ethereum-1") || rt.OpenSends("ethereum-1") != 1 {
		t.Fatalf("a replacement left the route open, or miscounted: %d", rt.OpenSends("ethereum-1"))
	}
	if _, _, err := rt.Reopen(); err == nil || !strings.Contains(err.Error(), "still open") {
		t.Fatalf("reopened with an open send record: %v", err)
	}
	if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc", lockOf(big)); err != nil {
		t.Fatal(err)
	}
	rt.RecordLoss(pk(9), "ugnot", 100, ChainGno, "inc", "collision")
	rt.RecordLoss(pk(10), "ugnot", 50, ChainGno, "inc-2", "collision")
	id, _ := rt.AuthorizeRecap("ugnot", 30, "inc")
	rt.Recapitalize(id, "ugnot", 30, alice)
	accepted, done, err := rt.Reopen()
	if err != nil || !done || rt.IsClosed() || accepted != 120 {
		t.Fatalf("%d %v", accepted, err)
	}
	d := rt.Denom("ugnot")
	if d.Totals.Accepted != 120 || d.Totals.Unrecovered() != 120 || d.Totals.Unresolved() != 0 {
		t.Fatalf("%+v", d.Totals)
	}
}

// Every owed refund is reserved: a receive's free lock and a claim payout
// never take the escrow a queued refund, held or not, needs (ADR pr6375
// §7.12).
func TestQueuedRefundsReserved(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(10_000)
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 8_000))
	rt.Settle(t0, 1, pk(1), OutcomeTimeout, true, lock) // held
	if !mustCredit(t, rt, t0, 5, "ugnot", alice, 3_000, lock) {
		t.Fatalf("a credit took the escrow a held refund needs")
	}
	if mustCredit(t, rt, t0, 6, "ugnot", bob, 2_000, lock) {
		t.Fatalf("swept a credit within the free lock")
	}
	// The claim pays only from what the refund leaves: 2000.
	paid := int64(0)
	for day := int64(1); day < 10; day++ {
		ps, _ := rt.PayClaims(t0+day*Day, 0, t0, "ugnot", 20, lock-paid)
		a, f := sumPay(ps)
		paid += a + f
	}
	if paid != 2_000 || lock-paid < rt.Denom("ugnot").Totals.QueuedRefunds {
		t.Fatalf("claims took %d of the refunds' reserve", paid)
	}
}

// Losses near the int64 maximum on two denoms never wrap the route's
// closure: it is decided denom by denom, sums saturate, and a loss past
// int64 in total is booked exactly (design review r2 #1).
func TestLossesNearMaximum(t *testing.T) {
	_, rt := newRoute(t)
	big := int64(5_000_000_000_000_000_000)
	if err := rt.RecordLoss(pk(1), "ugnot", big, ChainGno, "inc", "collision"); err != nil {
		t.Fatal(err)
	}
	if err := rt.RecordLoss(pk(2), "ibc/WETH", big, ChainEthereum, "inc", "collision"); err != nil {
		t.Fatal(err)
	}
	if !rt.ExposureClosed() || rt.Unresolved() != maxInt64 || rt.Unrecovered() != maxInt64 {
		t.Fatalf("closed %v unresolved %d", rt.IsClosed(), rt.Unresolved())
	}
	if err := rt.RecordLoss(pk(3), "ugnot", big, ChainGno, "inc-2", "collision"); err != nil {
		t.Fatalf("a loss past int64 in total refused: %v", err)
	}
	// One denom resolved: the other still closes the route.
	if err := rt.Accept("ugnot", big, "inc"); err != nil {
		t.Fatal(err)
	}
	if err := rt.Accept("ugnot", big, "inc-2"); err != nil {
		t.Fatal(err)
	}
	if !rt.ExposureClosed() || rt.IsClosed() {
		t.Fatalf("an unresolved denom left the route open, or a loss closed it like a replacement")
	}
}

// Batch losses never wrap: four or five paid claims of 2^62 voided together
// are booked exactly, the ledger's balances being wide (Codex round 3 #1,
// design review r2 #1), and a reopening accepts all of them.
func TestBatchLossesNeverWrap(t *testing.T) {
	for _, n := range []int{4, 5} {
		_, rt := newRoute(t)
		var keys []string
		for i := 0; i < n; i++ {
			k := pk(uint64(100 + i))
			rt.claims.Set(k, &Claim{Key: k, Denom: "ibc/WETH", To: alice, Amount: 1 << 62, Paid: 1 << 62, State: Done})
			keys = append(keys, k)
		}
		if err := rt.Void(keys, true, "inc"); err != nil {
			t.Fatalf("%d claims of 2^62: %v", n, err)
		}
		d := rt.Denom("ibc/WETH")
		if d.Totals.OpenUnresolved != maxInt64 || d.Totals.w[wUnres].hi != int64(n) {
			t.Fatalf("%d claims of 2^62: %+v", n, d.Totals)
		}
	}
	// A settlement's forged refunds are summed the same way.
	r, rt := newRoute(t)
	// Records no send could make together any more (InFlight bounds them):
	// written directly, as a ledger from before that bound would hold them.
	for i := uint64(1); i <= 4; i++ {
		rec := sendRec(i, "ibc/WETH", KindMint, 1<<62)
		rec.Refunded, rec.Outcome = 1<<62, OutcomeTimeout
		rt.sends.Set(rec.Key, &rec)
	}
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	var items []SettleItem
	for i := uint64(1); i <= 4; i++ {
		items = append(items, SettleItem{Seq: i, Action: SettleLoss, Amount: 1 << 62})
	}
	if _, err := settleProven(rt, "ethereum-1", items, "inc", lockOf(0)); err != nil {
		t.Fatalf("a settlement's losses past int64: %v", err)
	}
	if w := rt.Denom("ibc/WETH").Totals.w[wUnrec]; w.hi != 4 || w.lo != 0 {
		t.Fatalf("booked %+v", w)
	}
}

// A reopening over many incidents runs in bounded batches, continued by
// anyone; the route opens with the last (ADR pr6375 §5.4 kind 13).
func TestReopenInBatches(t *testing.T) {
	r, rt := newRoute(t)
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	n := ReopenBatch*2 + 5
	for i := 0; i < n; i++ {
		rt.RecordLoss(pk(uint64(1000+i)), "ugnot", 1, ChainGno, "inc-"+itoa(int64(i)), "collision")
	}
	if _, _, err := rt.ContinueReopen(); err == nil {
		t.Fatalf("continued a reopening never started")
	}
	total, done, err := rt.Reopen()
	if err != nil || done || !rt.IsClosed() {
		t.Fatalf("one batch opened %d incidents: %v %v", n, done, err)
	}
	if _, _, err := rt.Reopen(); err == nil {
		t.Fatalf("started twice")
	}
	// A loss booked between batches on an incident the first batch accepted
	// already, behind the cursor (Codex round 8 #5): the scan starts over.
	if err := rt.RecordLoss(pk(5000), "ugnot", 7, ChainGno, "inc-0", "collision"); err != nil {
		t.Fatal(err)
	}
	n += 7
	for !done {
		var a int64
		a, done, err = rt.ContinueReopen()
		if err != nil {
			t.Fatal(err)
		}
		total += a
	}
	if total != int64(n) || rt.IsClosed() || rt.Denom("ugnot").Totals.Unresolved() != 0 {
		t.Fatalf("accepted %d of %d", total, n)
	}
}

// A sweep entry a sweep decision paid is voided as forged on a live route,
// its payout booked as the loss exactly once (Codex round 10 #3): payout,
// forged void, then every other path to the same loss is refused.
func TestForgedVoidOfPaidSweep(t *testing.T) {
	r, rt := newRoute(t)
	rt.Credit(t0, 10, 0, pk(6), "ugnot", alice, 400, ByPacket, "bridge realm", big)
	if _, err := rt.PaySweeps([]string{pk(6)}, bob, big); err != nil {
		t.Fatal(err)
	}
	swept := rt.Denom("ugnot").Totals.Swept
	if !rt.Voidable(pk(6), true) || rt.Voidable(pk(6), false) {
		t.Fatalf("a paid sweep entry is voidable as forged only")
	}
	if err := rt.Void([]string{pk(6)}, true, "inc"); err != nil {
		t.Fatal(err)
	}
	d := rt.Denom("ugnot")
	if d.Totals.Lost != 400 || d.Totals.Swept != swept || !rt.LossBooked(DirRecv, pk(6)) {
		t.Fatalf("%+v", d.Totals)
	}
	if rt.Void([]string{pk(6)}, true, "inc") == nil || rt.RecordLoss(pk(6), "ugnot", 400, ChainGno, "inc", "forged-delivery") == nil {
		t.Fatalf("booked the paid sweep's loss twice")
	}
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 6, Action: SettleForgedReceive, Amount: 400}}, "inc", lockOf(big), activeAll); err == nil {
		t.Fatalf("settled the voided sweep's loss again")
	}
	if rt.Denom("ugnot").Totals.Lost != 400 {
		t.Fatalf("lost %d", rt.Denom("ugnot").Totals.Lost)
	}
}

// The loss ledger admits a loss against its outstanding balances, not its
// lifetime totals (Codex round 11 #1): a loss fully recovered frees its
// capacity, so repeated losses crossing MaxInt64 in total are booked; the
// lifetime statistics saturate.
func TestLossCapacityFreedByRecovery(t *testing.T) {
	_, rt := newRoute(t)
	const big5 = int64(5_000_000_000_000_000_000)
	for i := 0; i < 3; i++ {
		incident := "inc-" + itoa(int64(i))
		if err := rt.RecordLoss(pk(uint64(100+i)), "ugnot", big5, ChainGno, incident, "collision"); err != nil {
			t.Fatalf("loss %d: %v", i, err)
		}
		if i == 2 {
			break
		}
		id, err := rt.AuthorizeRecap("ugnot", big5, incident)
		if err != nil {
			t.Fatal(err)
		}
		if err := rt.Recapitalize(id, "ugnot", big5, alice); err != nil {
			t.Fatal(err)
		}
	}
	d := rt.Denom("ugnot")
	if d.Totals.Unrecovered() != big5 || d.Totals.Unresolved() != big5 || d.Totals.Lost != maxInt64 {
		t.Fatalf("%+v", d.Totals)
	}
	// The outstanding balance itself is wide: a loss past int64 in total is
	// booked exactly.
	if err := rt.RecordLoss(pk(200), "ugnot", big5, ChainGno, "inc-9", "collision"); err != nil {
		t.Fatalf("a loss past int64 in total refused: %v", err)
	}
	if d.Totals.Unrecovered() != maxInt64 {
		t.Fatalf("%+v", d.Totals)
	}
}

// A replacement during a batched reopening aborts it (Codex round 13 #2):
// the route stays closed, the new incident's client must be settled, and the
// reopening starts again from a decision.
func TestReplacementAbortsReopening(t *testing.T) {
	r, rt := newRoute(t)
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	for i := 0; i < ReopenBatch+5; i++ {
		rt.RecordLoss(pk(uint64(1000+i)), "ugnot", 1, ChainGno, "inc-"+itoa(int64(i)), "collision")
	}
	if _, done, err := rt.Reopen(); err != nil || done || !rt.Reopening {
		t.Fatalf("%v %v", done, err)
	}
	if err := replaceReady(r, "ethereum-1", "ethereum-3", 0, 2000); err != nil {
		t.Fatal(err)
	}
	if rt.Reopening || !rt.IsClosed() || rt.Client != "ethereum-3" || len(rt.Replaced) != 2 {
		t.Fatalf("%+v", rt)
	}
	if _, _, err := rt.ContinueReopen(); err == nil {
		t.Fatalf("continued an aborted reopening")
	}
	total, done, err := rt.Reopen()
	for err == nil && !done {
		var a int64
		a, done, err = rt.ContinueReopen()
		total += a
	}
	if err != nil || rt.IsClosed() || rt.Denom("ugnot").Totals.Unresolved() != 0 {
		t.Fatalf("%v %d", err, total)
	}
}

// A deficit accepted, even through a reopening, is still recapitalized by a
// new authorization (Codex round 13 #1): accept, authorize, fund, and the
// unrecovered balance is zero; a revoked authorization stays refused.
func TestRecapitalizeAcceptedDeficit(t *testing.T) {
	r, rt := newRoute(t)
	d := rt.Denom("ugnot")
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	rt.RecordLoss(pk(10), "ugnot", 100, ChainGno, "inc", "collision")
	if _, done, err := rt.Reopen(); err != nil || !done || d.Totals.Unresolved() != 0 || d.Totals.Unrecovered() != 100 {
		t.Fatalf("%v %+v", err, d.Totals)
	}
	revoked, err := rt.AuthorizeRecap("ugnot", 40, "inc")
	if err != nil {
		t.Fatal(err)
	}
	rt.RevokeRecap(revoked)
	id, err := rt.AuthorizeRecap("ugnot", 100, "inc")
	if err != nil {
		t.Fatalf("no authorization against an accepted deficit: %v", err)
	}
	if rt.Recapitalize(revoked, "ugnot", 40, alice) == nil {
		t.Fatalf("paid a revoked authorization")
	}
	if err := rt.Recapitalize(id, "ugnot", 100, alice); err != nil {
		t.Fatal(err)
	}
	if d.Totals.Unrecovered() != 0 || d.Totals.Unresolved() != 0 || rt.Incident("ugnot", "inc").OpenUnrecovered != 0 {
		t.Fatalf("%+v", d.Totals)
	}
	if _, err := rt.AuthorizeRecap("ugnot", 1, "inc"); err == nil {
		t.Fatalf("authorized beyond the unrecovered losses")
	}
}

// remedyRoute is a route with an open claim (1), a withheld claim (2) and an
// owed sweep entry (20), a replacement closing it, and a loss of 100 of
// incident "inc".
func remedyRoute(t *testing.T) *Route {
	r, rt := newRoute(t)
	lock := int64(100_000)
	mustCredit(t, rt, t0, 1, "ugnot", alice, 50_000, lock)
	mustCredit(t, rt, t0, 2, "ugnot", bob, 3_000, lock)
	if _, err := rt.Credit(t0, 10, 0, pk(20), "ugnot", alice, 500, ByPacket, "bridge realm", big); err != nil {
		t.Fatal(err)
	}
	if err := rt.Void([]string{pk(2)}, false, "inc"); err != nil {
		t.Fatal(err)
	}
	if err := replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000); err != nil {
		t.Fatal(err)
	}
	if err := rt.RecordLoss(pk(10), "ugnot", 100, ChainGno, "inc", "collision"); err != nil {
		t.Fatal(err)
	}
	return rt
}

// A reduction repairs an accepted deficit, of each kind of liability: it is
// bounded by the unrecovered losses, not the unresolved ones (Codex round 15
// #1).
func TestReduceAcceptedDeficit(t *testing.T) {
	for _, key := range []string{pk(1), pk(2), pk(20)} {
		rt := remedyRoute(t)
		d := rt.Denom("ugnot")
		if err := rt.Accept("ugnot", 100, "inc"); err != nil {
			t.Fatal(err)
		}
		if err := rt.Reduce(key, 100, "inc"); err != nil {
			t.Fatalf("%s: an accepted deficit not reduced: %v", key, err)
		}
		it := rt.Incident("ugnot", "inc")
		if d.Totals.Unrecovered() != 0 || d.Totals.Unresolved() != 0 || it.OpenUnrecovered != 0 || it.Reduced != 100 || it.Accepted != 100 {
			t.Fatalf("%s: %+v %+v", key, d.Totals, it)
		}
		if rt.Reduce(key, 1, "inc") == nil {
			t.Fatalf("%s: reduced beyond the unrecovered losses", key)
		}
	}
}

// Every loss-resolution path follows one rule, before and after an
// acceptance (by Accept or by a reopening): a recapitalization or a
// reduction is bounded by the unrecovered losses and lowers the unresolved
// ones only as far as they remain; an acceptance lowers only the unresolved
// ones; a revocation changes neither.
func TestRemedyOrder(t *testing.T) {
	const incident = "inc"
	paths := []struct {
		name     string
		apply    func(rt *Route) error
		recovers bool
		accepts  bool
	}{
		{"recapitalize", func(rt *Route) error {
			id, err := rt.AuthorizeRecap("ugnot", 60, incident)
			if err != nil {
				return err
			}
			return rt.Recapitalize(id, "ugnot", 60, alice)
		}, true, false},
		{"reduce claim", func(rt *Route) error { return rt.Reduce(pk(1), 60, incident) }, true, false},
		{"reduce withheld", func(rt *Route) error { return rt.Reduce(pk(2), 60, incident) }, true, false},
		{"reduce sweep", func(rt *Route) error { return rt.Reduce(pk(20), 60, incident) }, true, false},
		{"accept", func(rt *Route) error { return rt.Accept("ugnot", 60, incident) }, false, true},
		{"revoke", func(rt *Route) error {
			id, err := rt.AuthorizeRecap("ugnot", 60, incident)
			if err != nil {
				return err
			}
			return rt.RevokeRecap(id)
		}, false, false},
	}
	acceptances := []struct {
		name string
		run  func(rt *Route) error
	}{
		{"Accept", func(rt *Route) error {
			if rest := rt.Incident("ugnot", incident).OpenUnresolved; rest > 0 {
				return rt.Accept("ugnot", rest, incident)
			}
			return nil
		}},
		{"reopen", func(rt *Route) error {
			_, done, err := rt.Reopen()
			if err == nil && !done {
				return errors.New("reopen not done")
			}
			return err
		}},
	}
	for _, p := range paths {
		for _, a := range acceptances {
			for _, after := range []bool{false, true} {
				name := p.name + " before " + a.name
				if after {
					name = p.name + " after " + a.name
				}
				rt := remedyRoute(t)
				var perr error
				if after {
					if err := a.run(rt); err != nil {
						t.Fatalf("%s: %v", name, err)
					}
					perr = p.apply(rt)
				} else {
					perr = p.apply(rt)
					if err := a.run(rt); err != nil {
						t.Fatalf("%s: %v", name, err)
					}
				}
				// Only an acceptance needs something unresolved left.
				if refused := after && p.accepts; (perr != nil) != refused {
					t.Fatalf("%s: refused %v, want %v (%v)", name, perr != nil, refused, perr)
				}
				wantUnrec := int64(100)
				if p.recovers {
					wantUnrec = 40
				}
				d := rt.Denom("ugnot")
				it := rt.Incident("ugnot", incident)
				if it.OpenUnresolved != 0 || d.Totals.Unresolved() != 0 || it.OpenUnrecovered != wantUnrec || d.Totals.Unrecovered() != wantUnrec {
					t.Fatalf("%s: unresolved %d, unrecovered %d, want 0 and %d", name, it.OpenUnresolved, it.OpenUnrecovered, wantUnrec)
				}
				if it.Accepted+it.Reduced+it.Recapitalized < 100 {
					t.Fatalf("%s: resolved %+v", name, it)
				}
			}
		}
	}
}

// A claim whose recipient became a bridge realm after its credit is moved to
// the owed sweep at payout, exactly: its remainder leaves what is owed for
// what is swept, it carries what the claim paid, a forged void books that
// paid part as the loss, and only a sweep decision pays the rest.
func TestPayClaimsSweepsBridgeRealm(t *testing.T) {
	rt, lock := setupClaims(t) // claim 1 to alice paid in part, 2 to bob open
	d := rt.Denom("ugnot")
	mustCredit(t, rt, t0, 4, "ugnot", alice, 1_000, lock)
	c1, _ := rt.Claim(pk(1))
	if c1.Paid == 0 {
		t.Fatalf("setup: claim 1 unpaid")
	}
	owed, swept := d.Totals.Owed, d.Totals.Swept
	isAlice := func(a address) bool { return a == alice }
	ps, moved, err := rt.PayClaimsSweeping(t0+2*Day, 0, t0, "ugnot", 10, lock, isAlice)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range ps {
		if p.To == alice {
			t.Fatalf("paid a bridge realm: %+v", p)
		}
	}
	if len(moved) != 2 || moved[0] != pk(1) || moved[1] != pk(4) {
		t.Fatalf("moved %v", moved)
	}
	paidBob, feeBob := sumPay(ps)
	rem := c1.Remaining() + 1_000
	if d.Totals.Owed != owed-rem-paidBob-feeBob || d.Totals.Swept != swept+rem {
		t.Fatalf("owed %d swept %d, want %d %d", d.Totals.Owed, d.Totals.Swept, owed-rem-paidBob-feeBob, swept+rem)
	}
	if _, ok := rt.Claim(pk(1)); ok {
		t.Fatalf("the moved claim stayed")
	}
	e, _ := rt.Sweep(pk(1))
	if !e.FromClaim || e.ClaimPaid != c1.Paid || e.Amount != c1.Remaining() || e.Reason != "bridge realm" || e.Paid {
		t.Fatalf("%+v", e)
	}
	if rt.Waiting("ugnot") > 1 {
		t.Fatalf("alice still waiting")
	}
	if err := rt.CreditByVote(t0, 10, 0, pk(4), "ugnot", bob, 1_000, lock); err == nil {
		t.Fatalf("credited by vote a receive credited as a claim already")
	}
	if !rt.Voidable(pk(1), true) || rt.Voidable(pk(1), false) {
		t.Fatalf("a moved entry is voidable as forged only")
	}
	swept = d.Totals.Swept
	if err := rt.Void([]string{pk(1)}, true, "inc"); err != nil {
		t.Fatal(err)
	}
	if d.Totals.Swept != swept-c1.Remaining() || d.Totals.Unrecovered() != c1.Paid {
		t.Fatalf("void: swept %d unrecovered %d", d.Totals.Swept, d.Totals.Unrecovered())
	}
	if _, err := rt.PaySweeps([]string{pk(4)}, carol, lock); err != nil {
		t.Fatalf("a sweep decision cannot pay the moved entry: %v", err)
	}
}

// An incident holds at most MaxOpenRecaps unpaid authorizations on a denom,
// so a reduction's revocation walks a bounded list once; paying or revoking
// one frees a place, and a reduction revokes the newest first, in one pass
// (docs-vs-code review round 4 #3).
func TestOpenRecapsBounded(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000)
	mustCredit(t, rt, t0, 1, "ugnot", alice, 50_000, lock)
	if err := rt.RecordLoss(pk(10), "ugnot", 1_000, ChainGno, "inc", "collision"); err != nil {
		t.Fatal(err)
	}
	var ids []int64
	for i := 0; i < MaxOpenRecaps; i++ {
		id, err := rt.AuthorizeRecap("ugnot", 10, "inc")
		if err != nil {
			t.Fatalf("authorization %d: %v", i, err)
		}
		ids = append(ids, id)
	}
	if _, err := rt.AuthorizeRecap("ugnot", 10, "inc"); err == nil {
		t.Fatalf("authorized beyond %d open authorizations", MaxOpenRecaps)
	}
	if err := rt.RevokeRecap(ids[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.AuthorizeRecap("ugnot", 10, "inc"); err != nil {
		t.Fatalf("a revocation frees a place: %v", err)
	}
	// 64 open authorizations of 10 (640) against 1,000 unrecovered: a
	// reduction of 700 leaves 300, so the newest 34 are revoked.
	if err := rt.Reduce(pk(1), 700, "inc"); err != nil {
		t.Fatal(err)
	}
	if got := rt.openRecaps("ugnot", "inc", 0).sat(); got != 300 {
		t.Fatalf("open after the reduction: %d", got)
	}
	r, _ := rt.Recap(ids[1])
	last, _ := rt.Recap(rt.nRecaps)
	if r.Revoked || !last.Revoked {
		t.Fatalf("the newest are revoked first: %+v %+v", r, last)
	}
}

// The loss ledger never refuses a loss for its outstanding balances (design
// review r2 #1): with q = MaxInt64/2, three cycles of a return burning q,
// delivered, then refunded by a forged acknowledgement, leave three losses
// of q to book in reconciliation, 3q past int64; each settles, and the
// reopening accepts all of them and opens the route.
func TestLossLedgerBeyondInt64(t *testing.T) {
	const q = maxInt64 / 2
	r, rt := newRoute(t)
	cfg := DenomConfig{Kind: KindMint, CapFloor: maxInt64, SupplyCap: maxInt64, Fee: 10, FeeFloor: 1, RefundCap: maxInt64}
	if err := rt.SetDenom("ibc/BIG", cfg, t0, 0, q); err != nil {
		t.Fatal(err)
	}
	d := rt.Denom("ibc/BIG")
	for i := uint64(1); i <= 3; i++ {
		rt.RecordSend(sendRec(i, "ibc/BIG", KindMint, q))
		if pay, err := rt.Settle(t0+int64(i)*Day, 1, pk(i), OutcomeError, false, 0); err != nil || pay != q {
			t.Fatalf("cycle %d: forged refund %d %v", i, pay, err)
		}
	}
	replaceReady(r, "ethereum-1", "ethereum-2", 0, 1000)
	for i := uint64(1); i <= 3; i++ {
		if _, err := settleProven(rt, "ethereum-1", []SettleItem{{Seq: i, Action: SettleLoss, Amount: q}}, "inc", lockOf(0)); err != nil {
			t.Fatalf("loss %d: %v", i, err)
		}
	}
	if d.Totals.OpenUnrecovered != maxInt64 || d.Totals.OpenUnresolved != maxInt64 {
		t.Fatalf("%+v", d.Totals)
	}
	if _, done, err := rt.Reopen(); err != nil || !done || rt.IsClosed() || d.Totals.OpenUnresolved != 0 || d.Totals.OpenUnrecovered != maxInt64 {
		t.Fatalf("reopen: %v %v %+v", done, err, d.Totals)
	}
}

// A credit by vote of a packet an early client received, after many
// replacements (design review r9 #2): the route's client check is an
// indexed lookup (HasClient), not a scan of the replacement list.
func TestCreditByVoteAfterManyReplacements(t *testing.T) {
	r := NewRegistry()
	rt, err := r.Enroll("ethereum-1", collector, t0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := rt.SetDenom("ugnot", gnot(), t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	const lock = int64(100_000)
	if !mustCredit(t, rt, t0, 4, "ugnot", carol, lock, 0) { // no free lock: swept
		t.Fatalf("setup: not swept")
	}
	for i := 2; i <= 40; i++ {
		if err := replaceReady(r, "ethereum-1", "ethereum-"+strconv.Itoa(i), 0, int64(i*1000)); err != nil {
			t.Fatal(err)
		}
	}
	if !rt.HasClient("ethereum-1") || !rt.HasClient("ethereum-20") || !rt.HasClient("ethereum-40") || rt.HasClient("ethereum-41") {
		t.Fatalf("client membership after 39 replacements")
	}
	if _, done, err := rt.Reopen(); err != nil || !done {
		t.Fatalf("reopen: %v", err)
	}
	if err := rt.CreditByVote(t0, 50_000, 0, pk(4), "ugnot", carol, lock, 2*lock); err != nil {
		t.Fatal(err)
	}
}

// A reduction against losses past int64 revokes only the authorizations it
// conflicts with (code review r51 #1): an incident's exact losses of
// MaxInt64 + 1000, an authorization of 1500, then a reduction of
// MaxInt64 - 1000 leaves 2000, so the authorization stays and is payable.
// The reduction takes an open claim, a withheld one or an owed sweep entry.
func TestReductionBeyondInt64KeepsAuthorization(t *testing.T) {
	const m = maxInt64
	for _, kind := range []string{"open", "withheld", "sweep"} {
		_, rt := newRoute(t)
		switch kind {
		case "sweep":
			if !mustCredit(t, rt, t0, 5, "ugnot", alice, m-1000, 0) {
				t.Fatalf("%s: setup: not swept", kind)
			}
		default:
			if mustCredit(t, rt, t0, 5, "ugnot", alice, m-1000, m) {
				t.Fatalf("%s: setup: swept", kind)
			}
		}
		if kind == "withheld" {
			if err := rt.Void([]string{pk(5)}, false, "other"); err != nil {
				t.Fatal(err)
			}
		}
		if err := rt.RecordLoss(PacketKey("ethereum-1", 90), "ugnot", m/2, ChainGno, "inc", "forged"); err != nil {
			t.Fatal(err)
		}
		if err := rt.RecordLoss(PacketKey("ethereum-1", 91), "ugnot", m/2+1001, ChainGno, "inc", "forged"); err != nil {
			t.Fatal(err)
		}
		id, err := rt.AuthorizeRecap("ugnot", 1500, "inc")
		if err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		if err := rt.Reduce(pk(5), m-1000, "inc"); err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		if r, _ := rt.Recap(id); r.Revoked {
			t.Fatalf("%s: revoked an authorization the reduction leaves room for", kind)
		}
		if err := rt.Recapitalize(id, "ugnot", 1500, alice); err != nil {
			t.Fatalf("%s: the authorization is not payable: %v", kind, err)
		}
		if it := rt.Incident("ugnot", "inc"); it.OpenUnrecovered != 500 {
			t.Fatalf("%s: %d left unrecovered", kind, it.OpenUnrecovered)
		}
	}
}

// What a recapitalization may still restore is read from the exact balance:
// with losses of MaxInt64 + 1000 and an authorization of 1000 open, another
// of MaxInt64 is not refused (code review r51 #1, the same arithmetic).
func TestRecapitalizableBeyondInt64(t *testing.T) {
	_, rt := newRoute(t)
	rt.RecordLoss(PacketKey("ethereum-1", 90), "ugnot", maxInt64/2, ChainGno, "inc", "forged")
	rt.RecordLoss(PacketKey("ethereum-1", 91), "ugnot", maxInt64/2+1001, ChainGno, "inc", "forged")
	if _, err := rt.AuthorizeRecap("ugnot", 1000, "inc"); err != nil {
		t.Fatal(err)
	}
	if _, err := rt.AuthorizeRecap("ugnot", maxInt64, "inc"); err != nil {
		t.Fatalf("refused what the exact balance holds: %v", err)
	}
	if _, err := rt.AuthorizeRecap("ugnot", 1, "inc"); err == nil {
		t.Fatalf("authorized beyond the losses")
	}
}

// The payout chain books a loss (main ADR design review r21 #1): a forged
// receive that minted an Ethereum-native token's vouchers here is booked
// here by its forged void, an authoritative record, and resolved here by a
// reduction or an accepted deficit.
func TestForgedVoucherMintBookedHere(t *testing.T) {
	_, rt := newRoute(t)
	mustCredit(t, rt, t0, 5, "ibc/WETH", alice, 3_000, big)
	mustCredit(t, rt, t0, 6, "ibc/WETH", bob, 2_000, big)
	rt.PayClaims(t0+Day, 0, t0, "ibc/WETH", 2, big)
	c5, _ := rt.Claim(pk(5))
	if c5.Paid == 0 {
		t.Fatalf("setup: %+v", c5)
	}
	if err := rt.Void([]string{pk(5)}, true, "inc"); err != nil {
		t.Fatal(err)
	}
	it := rt.Incident("ibc/WETH", "inc")
	if it.Mirror || it.OpenUnrecovered != c5.Paid {
		t.Fatalf("not booked here as authoritative: %+v", it)
	}
	if err := rt.Reduce(pk(6), 1, "inc"); err != nil {
		t.Fatalf("an authoritative loss is not reducible: %v", err)
	}
	if err := rt.Accept("ibc/WETH", rt.Incident("ibc/WETH", "inc").OpenUnresolved, "inc"); err != nil {
		t.Fatal(err)
	}
}

// A mirror of a loss paid on Ethereum (RecordLoss, chain "ethereum") is
// resolved only by an accepted deficit (code review r60 #4): a reduction of
// an open claim, a withheld claim or an owed sweep entry against it is
// refused, a recapitalization too, and the incident takes no loss paid here.
func TestMirrorLossAcceptedOnly(t *testing.T) {
	_, rt := newRoute(t)
	if err := rt.RecordLoss(PacketKey("ethereum-1", 90), "ugnot", 500, ChainEthereum, "m", "collision"); err != nil {
		t.Fatal(err)
	}
	if !rt.Incident("ugnot", "m").Mirror {
		t.Fatalf("not marked a mirror")
	}
	mustCredit(t, rt, t0, 5, "ugnot", alice, 1_000, big) // open
	mustCredit(t, rt, t0, 6, "ugnot", bob, 1_000, big)   // withheld below
	if err := rt.Void([]string{pk(6)}, false, "w"); err != nil {
		t.Fatal(err)
	}
	if !mustCredit(t, rt, t0, 7, "ugnot", carol, 1_000, 0) { // swept: no free lock
		t.Fatalf("setup: not swept")
	}
	for _, k := range []string{pk(5), pk(6), pk(7)} {
		if err := rt.Reduce(k, 100, "m"); err == nil || !strings.Contains(err.Error(), "accepted deficit only") {
			t.Fatalf("reduced %s against a mirror: %v", k, err)
		}
	}
	if _, err := rt.AuthorizeRecap("ugnot", 100, "m"); err == nil {
		t.Fatalf("authorized a recapitalization of a mirror")
	}
	if err := rt.Void([]string{pk(5)}, true, "m"); err == nil {
		t.Fatalf("booked a loss paid here under a mirror incident")
	}
	if err := rt.Accept("ugnot", 500, "m"); err != nil || rt.Incident("ugnot", "m").OpenUnresolved != 0 {
		t.Fatalf("the mirror is not accepted: %v", err)
	}
}
