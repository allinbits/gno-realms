package controls

import (
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
	if lj != "[]" {
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
	if err := rt.RecordLoss(pk(10), "ugnot", 1_000, ChainEthereum, "inc", "refund paid for a delivered packet"); err != nil {
		t.Fatal(err)
	}
	if err := rt.RecordLoss(pk(10), "ugnot", 1_000, ChainEthereum, "inc", "refund paid for a delivered packet"); err == nil {
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
	if err := r.Replace("ethereum-1", "ethereum-1", 0); err == nil {
		t.Fatalf("replaced with itself")
	}
	if err := r.Replace("ethereum-9", "ethereum-2", 0); err == nil {
		t.Fatalf("replaced an unknown route")
	}
	if err := r.Replace("ethereum-1", "ethereum-2", 0); err != nil {
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
	if err := r.Replace("ethereum-1", "ethereum-1", 0); err == nil {
		t.Fatalf("re-used a retired client")
	}
	if err := r.Replace("ethereum-1", "ethereum-3", 0); err != nil {
		t.Fatal(err)
	}
	if len(rt.Replaced) != 2 || r.RetiredRouteOf("ethereum-2") != "ethereum-1" {
		t.Fatalf("%+v", rt.Replaced)
	}
	// A retired client id is final: never migrated back to.
	if err := r.Replace("ethereum-1", "ethereum-2", 0); err == nil {
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
	// The JSON escapes what the counterparty wrote.
	mustCredit(t, rt, t0, 3, "ugnot", `g1"x`, 1, 100_000) // swept: below the fee
	if !strings.Contains(rd.SweepsJSON("ethereum-1", ""), `"to":"g1\"x"`) {
		t.Fatalf("escaping: %s", rd.SweepsJSON("ethereum-1", ""))
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
	// The funding falls through: an accepted deficit supersedes it.
	if err := rt.Accept("ugnot", 101, "inc-a"); err == nil {
		t.Fatalf("accepted more than the loss")
	}
	if err := rt.Accept("ugnot", 100, "inc-a"); err != nil {
		t.Fatal(err)
	}
	if r, _ := rt.Recap(id); !r.Revoked {
		t.Fatalf("the superseded authorization stands: %+v", r)
	}
	if err := rt.Recapitalize(id, "ugnot", 100, alice); err == nil {
		t.Fatalf("paid a superseded authorization")
	}
	if d.Totals.Unresolved() != 0 || d.Totals.Recapitalized != 0 {
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
	if _, err := rt.Reopen(); err == nil {
		t.Fatalf("reopened an open route")
	}
	rt.RecordSend(sendRec(1, "ugnot", KindUnescrow, 1_000)) // in flight
	rt.RecordSend(sendRec(2, "ugnot", KindUnescrow, 1_000))
	rt.Settle(t0, 1, pk(2), OutcomeSuccess, false, big) // closed
	if err := r.Replace("ethereum-1", "ethereum-2", 2); err != nil {
		t.Fatal(err)
	}
	if !rt.IsClosed() || !(Reader{r: r}).Closed("ethereum-1") || rt.OpenSends("ethereum-1") != 1 {
		t.Fatalf("a replacement left the route open, or miscounted: %d", rt.OpenSends("ethereum-1"))
	}
	if _, err := rt.Reopen(); err == nil || !strings.Contains(err.Error(), "still open") {
		t.Fatalf("reopened with an open send record: %v", err)
	}
	if _, err := rt.SettleRecords("ethereum-1", []SettleItem{{Seq: 1, Action: SettleDelivered}}, "inc", lockOf(big)); err != nil {
		t.Fatal(err)
	}
	rt.RecordLoss(pk(9), "ugnot", 100, ChainGno, "inc", "collision")
	rt.RecordLoss(pk(10), "ugnot", 50, ChainGno, "inc-2", "collision")
	id, _ := rt.AuthorizeRecap("ugnot", 30, "inc")
	rt.Recapitalize(id, "ugnot", 30, alice)
	accepted, err := rt.Reopen()
	if err != nil || rt.IsClosed() || accepted != 120 {
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
// closure: it is decided denom by denom, sums saturate, and a loss the
// ledger could not hold is refused (Codex round 2 #2).
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
	if err := rt.RecordLoss(pk(3), "ugnot", big, ChainGno, "inc-2", "collision"); err == nil {
		t.Fatalf("recorded a loss the ledger cannot hold")
	}
	// One denom resolved: the other still closes the route.
	if err := rt.Accept("ugnot", big, "inc"); err != nil {
		t.Fatal(err)
	}
	if !rt.ExposureClosed() || rt.IsClosed() {
		t.Fatalf("an unresolved denom left the route open, or a loss closed it like a replacement")
	}
}

// Batch losses are summed with checked additions: four or five paid claims
// of 2^62 voided together would wrap the sum to zero or to a positive value
// below the truth (Codex round 3 #1).
func TestBatchLossesNeverWrap(t *testing.T) {
	for _, n := range []int{4, 5} {
		_, rt := newRoute(t)
		var keys []string
		for i := 0; i < n; i++ {
			k := pk(uint64(100 + i))
			rt.claims.Set(k, &Claim{Key: k, Denom: "ibc/WETH", To: alice, Amount: 1 << 62, Paid: 1 << 62, State: Done})
			keys = append(keys, k)
		}
		if err := rt.Void(keys, true, "inc"); err == nil {
			t.Fatalf("%d claims of 2^62: a wrapped loss was booked: %+v", n, rt.Denom("ibc/WETH").Totals)
		}
		if rt.Denom("ibc/WETH").Totals.Lost != 0 {
			t.Fatalf("a refused void changed the ledger")
		}
	}
	// A settlement's forged refunds are summed the same way.
	r, rt := newRoute(t)
	for i := uint64(1); i <= 4; i++ {
		rec := sendRec(i, "ibc/WETH", KindMint, 1<<62)
		rt.RecordSend(rec)
		rt.send(pk(i)).Refunded = 1 << 62
		rt.send(pk(i)).Outcome = OutcomeTimeout
	}
	r.Replace("ethereum-1", "ethereum-2", 0)
	var items []SettleItem
	for i := uint64(1); i <= 4; i++ {
		items = append(items, SettleItem{Seq: i, Action: SettleLoss, Amount: 1 << 62})
	}
	if _, err := rt.SettleRecords("ethereum-1", items, "inc", lockOf(0)); err == nil {
		t.Fatalf("a wrapped settlement loss was booked")
	}
}
