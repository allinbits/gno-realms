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
	if err := rt.Reduce(pk(3), 1, "inc"); err == nil {
		t.Fatalf("reduced a sweep entry")
	}
}

func TestRegistryReplace(t *testing.T) {
	r, rt := newRoute(t)
	if err := r.Replace("ethereum-1", "ethereum-1"); err == nil {
		t.Fatalf("replaced with itself")
	}
	if err := r.Replace("ethereum-9", "ethereum-2"); err == nil {
		t.Fatalf("replaced an unknown route")
	}
	if err := r.Replace("ethereum-1", "ethereum-2"); err != nil {
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
	if err := r.Replace("ethereum-1", "ethereum-1"); err == nil {
		t.Fatalf("re-used a retired client")
	}
	if err := r.Replace("ethereum-1", "ethereum-3"); err != nil {
		t.Fatal(err)
	}
	if len(rt.Replaced) != 2 || r.RetiredRouteOf("ethereum-2") != "ethereum-1" {
		t.Fatalf("%+v", rt.Replaced)
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

// An authorized recapitalization holds its part of the incident's losses:
// no reduction or accepted deficit can resolve the same loss again, and the
// payment re-checks what the incident still has to resolve (Codex review
// #6).
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
	// The alternative resolutions of the same loss are refused while the
	// authorization holds it.
	if err := rt.Reduce(pk(2), 100, "inc-a"); err == nil {
		t.Fatalf("reduced a loss an authorization holds")
	}
	if err := rt.Accept("ugnot", 100, "inc-a"); err == nil {
		t.Fatalf("accepted a loss an authorization holds")
	}
	if err := rt.Recapitalize(id, "ugnot", 100, alice); err != nil {
		t.Fatal(err)
	}
	if d.Totals.Unrecovered() != 0 || rt.Incident("ugnot", "inc-a").Recapitalized != 100 {
		t.Fatalf("%+v", d.Totals)
	}
	// Another incident's loss leaves this one's resolutions alone.
	rt.RecordLoss(pk(11), "ugnot", 50, ChainGno, "inc-c", "forged delivery")
	if err := rt.Reduce(pk(2), 50, "inc-a"); err == nil {
		t.Fatalf("reduced against a resolved incident")
	}
	if err := rt.Reduce(pk(2), 50, "inc-c"); err != nil {
		t.Fatal(err)
	}
	if d.Totals.Unrecovered() != 0 {
		t.Fatalf("%+v", d.Totals)
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
	if err := rt.CreditPending(t0, 20, 0, pk(61), "ibc/WETH", alice, 50, 51, 0); err != nil {
		t.Fatal(err)
	}
	checkClaimTotals(t, rt, "ugnot")
}
