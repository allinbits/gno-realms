package controls

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

var (
	collector = testutils.TestAddress("collector")
	alice     = testutils.TestAddress("alice")
	bob       = testutils.TestAddress("bob")
	carol     = testutils.TestAddress("carol")
)

const t0 = int64(1_700_000_000)

func gnot() DenomConfig {
	return DenomConfig{Kind: KindUnescrow, CapFloor: 10_000, Fee: 20, FeeFloor: 2, SendMax: 25_000, SendMin: 40, RefundCap: 10_000, Remote: "0x0000000000000000000000000000000000c0ffee"}
}

func mintCfg() DenomConfig {
	return DenomConfig{Kind: KindMint, CapFloor: 4_000, SupplyCap: 100_000, Fee: 10, FeeFloor: 1, RefundCap: 4_000}
}

func newRoute(t *testing.T) (*Registry, *Route) {
	r := NewRegistry()
	rt, err := r.Enroll("ethereum-1", collector, t0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := rt.SetDenom("ugnot", gnot(), t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := rt.SetDenom("ibc/WETH", mintCfg(), t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	return r, rt
}

// replaceReady replaces a route's client and prepares the replacement whole
// (PrepareReplacement), as a test that settles or reopens right after needs.
func replaceReady(r *Registry, key, newClient string, suspectFrom, height int64) error {
	if err := r.Replace(key, newClient, suspectFrom, height); err != nil {
		return err
	}
	for {
		if _, done, _ := r.Route(key).PrepareReplacement(MaxKeys); done {
			return nil
		}
	}
}

func pk(seq uint64) string { return PacketKey("ethereum-1", seq) }

func mustCredit(t *testing.T, rt *Route, now int64, seq uint64, denom string, to address, amount, lock int64) bool {
	t.Helper()
	swept, err := rt.Credit(now, 10, 0, pk(seq), denom, to, amount, ByPacket, "", lock)
	if err != nil {
		t.Fatalf("credit %d: %v", seq, err)
	}
	return swept
}

func sumPay(ps []Payment) (amount, fee int64) {
	for _, p := range ps {
		amount += p.Amount
		fee += p.Fee
	}
	return
}

// checkClaimTotals checks the claim accounting identities of a denom.
func checkClaimTotals(t *testing.T, rt *Route, denom string) {
	t.Helper()
	d := rt.Denom(denom)
	var owed, withheld, paid int64
	rt.claims.Iterate("", "", func(_ string, v any) bool {
		c := v.(*Claim)
		if c.Denom != denom {
			return false
		}
		if c.Paid > c.Amount || c.Paid < 0 {
			t.Fatalf("claim %s paid %d of %d", c.Key, c.Paid, c.Amount)
		}
		switch c.State {
		case Open:
			owed += c.Remaining()
		case Withheld:
			withheld += c.Remaining()
		case Done:
			if c.Remaining() != 0 {
				t.Fatalf("done claim %s owes %d", c.Key, c.Remaining())
			}
		}
		paid += c.Paid
		return false
	})
	if owed != d.Totals.Owed || withheld != d.Totals.Withheld {
		t.Fatalf("%s: owed %d/%d withheld %d/%d", denom, owed, d.Totals.Owed, withheld, d.Totals.Withheld)
	}
	if paid != d.Totals.Paid+d.Totals.Fees {
		t.Fatalf("%s: claims paid %d, totals %d+%d", denom, paid, d.Totals.Paid, d.Totals.Fees)
	}
}

func TestPacketKey(t *testing.T) {
	k := PacketKey("ethereum-12", 7)
	if k != "ethereum-12/00000000000000000007" {
		t.Fatalf("key %s", k)
	}
	c, s, ok := ParsePacketKey(k)
	if !ok || c != "ethereum-12" || s != 7 {
		t.Fatalf("parse %s %d %v", c, s, ok)
	}
	for _, bad := range []string{"", "x", "ethereum-1/7", "/00000000000000000007", "ethereum-1/00000000000000000000", "ethereum-1/0000000000000000000x", "x](y)/00000000000000000007", "a b/00000000000000000007"} {
		if _, _, ok := ParsePacketKey(bad); ok {
			t.Errorf("parsed %q", bad)
		}
	}
	if PacketKey("a", 2) > PacketKey("a", 10) {
		t.Errorf("keys do not sort by sequence")
	}
}

func TestEnrollAndDenoms(t *testing.T) {
	r, rt := newRoute(t)
	if _, err := r.Enroll("ethereum-1", collector, t0, 1); err == nil {
		t.Fatalf("enrolled twice")
	}
	if _, err := r.Enroll("ethereum-2", "bad", t0, 1); err == nil {
		t.Fatalf("bad collector")
	}
	if r.RouteOf("ethereum-1") != rt || r.Route("ethereum-1") != rt {
		t.Fatalf("lookup")
	}
	// A denom never changes accounting, and its cap floor never goes below launch.
	c := gnot()
	c.Kind = KindMint
	c.SupplyCap, c.SendMax, c.SendMin = 1, 0, 0
	if err := rt.SetDenom("ugnot", c, t0, 0, 0); err == nil {
		t.Fatalf("accounting changed")
	}
	c = gnot()
	c.CapFloor = 9_999
	if err := rt.SetDenom("ugnot", c, t0, 0, 0); err == nil || !strings.Contains(err.Error(), "launch value") {
		t.Fatalf("below launch: %v", err)
	}
	c.CapFloor = 20_000
	if err := rt.SetDenom("ugnot", c, t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if rt.Denom("ugnot").Config.CapFloor != 20_000 || rt.Denom("ugnot").LaunchCapFloor != 10_000 {
		t.Fatalf("config")
	}
}

func TestConfigValidateAndLoosens(t *testing.T) {
	if err := gnot().Validate(); err != nil {
		t.Fatal(err)
	}
	if err := mintCfg().Validate(); err != nil {
		t.Fatal(err)
	}
	bad := []func(c *DenomConfig){
		func(c *DenomConfig) { c.Kind = "x" },
		func(c *DenomConfig) { c.CapFloor = 0 },
		func(c *DenomConfig) { c.FeeFloor = 0 },
		func(c *DenomConfig) { c.Fee = 1 },                  // below the floor
		func(c *DenomConfig) { c.Fee = 2_501 },              // above cap/4
		func(c *DenomConfig) { c.SendMin = 0 },              // unescrow needs a minimum
		func(c *DenomConfig) { c.SendMax = 39 },             // max below min
		func(c *DenomConfig) { c.SupplyCap = 1 },            // unescrow has no supply cap
		func(c *DenomConfig) { c.RefundCap = 0 },            // refunds metered
		func(c *DenomConfig) { c.Fee, c.CapFloor = 20, 79 }, // cap floor below 4 fees
		func(c *DenomConfig) { c.Remote = "" },              // no Ethereum token (Codex review #17)
		func(c *DenomConfig) { c.Remote = "0x0000000000000000000000000000000000C0FFEE" },
		func(c *DenomConfig) { c.Remote = "0x0000000000000000000000000000000000000000" },
	}
	for i, m := range bad {
		c := gnot()
		m(&c)
		if c.Validate() == nil {
			t.Errorf("case %d validated: %+v", i, c)
		}
	}
	mc := mintCfg()
	mc.SendMax = 1
	if mc.Validate() == nil {
		t.Errorf("minted denom with send limits")
	}
	mc = mintCfg()
	mc.Remote = "0x0000000000000000000000000000000000c0ffee"
	if mc.Validate() == nil {
		t.Errorf("minted denom with a remote token")
	}
	other := gnot()
	other.Remote = "0x0000000000000000000000000000000000c0fffe"
	if !Loosens(gnot(), other) {
		t.Errorf("a new Ethereum token does not wait")
	}
	mc = mintCfg()
	mc.SupplyCap = 0
	if mc.Validate() == nil {
		t.Errorf("minted denom without supply cap")
	}

	base := gnot()
	cases := []struct {
		m     func(c *DenomConfig)
		loose bool
	}{
		{func(c *DenomConfig) {}, false},
		{func(c *DenomConfig) { c.CapFloor++ }, true},
		{func(c *DenomConfig) { c.CapFloor-- }, false},
		{func(c *DenomConfig) { c.Fee++ }, true},
		{func(c *DenomConfig) { c.Fee-- }, false},
		{func(c *DenomConfig) { c.SendMax++ }, true},
		{func(c *DenomConfig) { c.SendMax-- }, false},
		{func(c *DenomConfig) { c.SendMin-- }, true},
		{func(c *DenomConfig) { c.SendMin++ }, false},
		{func(c *DenomConfig) { c.RefundCap++ }, true},
		{func(c *DenomConfig) { c.RefundCap-- }, false},
		{func(c *DenomConfig) { c.FeeFloor-- }, true},
		{func(c *DenomConfig) { c.FeeFloor++ }, true},
		{func(c *DenomConfig) { c.SupplyCap++ }, true},
		{func(c *DenomConfig) { c.CapFloor--; c.Fee++ }, true},
	}
	for i, tc := range cases {
		n := base
		tc.m(&n)
		if Loosens(base, n) != tc.loose {
			t.Errorf("case %d: loosens %v", i, !tc.loose)
		}
	}
}

func TestCheckSend(t *testing.T) {
	_, rt := newRoute(t)
	d := rt.Denom("ugnot")
	for _, tc := range []struct {
		amount int64
		ok     bool
	}{{39, false}, {40, true}, {25_000, true}, {25_001, false}, {0, false}, {-1, false}} {
		if (d.CheckSend(tc.amount) == nil) != tc.ok {
			t.Errorf("send %d: ok %v", tc.amount, !tc.ok)
		}
	}
	// Voucher returns are never limited.
	if rt.Denom("ibc/WETH").CheckSend(1_000_000_000) != nil {
		t.Errorf("a voucher return was limited")
	}
}

func TestCreditBooksClaimOrSweep(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000)
	if mustCredit(t, rt, t0, 1, "ugnot", alice, 1_000, lock) {
		t.Fatalf("1000 swept")
	}
	if !mustCredit(t, rt, t0, 2, "ugnot", alice, 19, lock) {
		t.Fatalf("below the fee not swept")
	}
	// The free lock is the lock minus what open claims reserve.
	if mustCredit(t, rt, t0, 3, "ugnot", bob, 99_000, lock) {
		t.Fatalf("99000 swept with 99000 free")
	}
	if !mustCredit(t, rt, t0, 4, "ugnot", bob, 1, lock) {
		t.Fatalf("an amount below the fee")
	}
	if !mustCredit(t, rt, t0, 5, "ugnot", carol, 21, lock) {
		t.Fatalf("21 with 0 free not swept")
	}
	// A bridge-realm receiver is swept whatever the amount.
	swept, err := rt.Credit(t0, 10, 0, pk(6), "ugnot", alice, 500, ByPacket, "bridge realm", 1_000_000)
	if err != nil || !swept {
		t.Fatalf("reason: %v %v", swept, err)
	}
	e, ok := rt.Sweep(pk(6))
	if !ok || e.Reason != "bridge realm" || e.Amount != 500 {
		t.Fatalf("sweep entry %+v", e)
	}
	d := rt.Denom("ugnot")
	if d.Totals.Owed != 100_000 || d.Totals.Swept != 19+1+21+500 || d.Totals.Credited != 100_000 {
		t.Fatalf("totals %+v", d.Totals)
	}
	// A packet is credited once; an unknown denom or a non-positive amount is refused.
	if _, err := rt.Credit(t0, 10, 0, pk(1), "ugnot", alice, 50, ByPacket, "", lock); err == nil {
		t.Fatalf("credited twice")
	}
	if _, err := rt.Credit(t0, 10, 0, pk(9), "uatom", alice, 50, ByPacket, "", lock); err == nil {
		t.Fatalf("unknown denom")
	}
	if _, err := rt.Credit(t0, 10, 0, pk(9), "ugnot", alice, 0, ByPacket, "", lock); err == nil {
		t.Fatalf("zero amount")
	}
	checkClaimTotals(t, rt, "ugnot")
}

// A minted denom's receives stop at its supply cap: outstanding vouchers plus
// everything booked, before any state change.
func TestMintSupplyCap(t *testing.T) {
	_, rt := newRoute(t)
	if err := rt.CheckCredit("ibc/WETH", 100_000); err != nil {
		t.Fatal(err)
	}
	mustCredit(t, rt, t0, 1, "ibc/WETH", alice, 60_000, 0)
	if err := rt.CheckCredit("ibc/WETH", 40_001); err == nil {
		t.Fatalf("past the supply cap")
	}
	before := rt.Denom("ibc/WETH").Totals
	if _, err := rt.Credit(t0, 10, 0, pk(2), "ibc/WETH", bob, 40_001, ByPacket, "", 0); err == nil {
		t.Fatalf("credited past the supply cap")
	}
	if rt.Denom("ibc/WETH").Totals != before || rt.claims.Has(pk(2)) {
		t.Fatalf("a refused credit changed state")
	}
	mustCredit(t, rt, t0, 3, "ibc/WETH", bob, 40_000, 0)
	// A minted denom has no lock: no "above the lock" sweep.
	if _, ok := rt.Sweep(pk(3)); ok {
		t.Fatalf("swept a mint credit")
	}
}

// Meters start empty: nothing is paid at the moment of the credit.
func TestMetersStartEmpty(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000)
	mustCredit(t, rt, t0, 1, "ugnot", alice, 1_000, lock)
	ps, err := rt.PayClaims(t0, 0, t0, "ugnot", 20, lock)
	if err != nil || len(ps) != 0 {
		t.Fatalf("paid at launch: %v %v", ps, err)
	}
}

// The fee is the first installment, whole, and later installments pay what
// both meters allow.
func TestClaimFeeFirstThenInstallments(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000) // cap = max(10000, 10000) = 10000; recipient 2500/day
	mustCredit(t, rt, t0, 1, "ugnot", alice, 5_000, lock)
	// Credited at t0: the recipient's meter starts then. After an hour the
	// recipient meter holds 104 (2500/24), the bridge 416.
	now := t0 + 3600
	ps, err := rt.PayClaims(now, 0, t0, "ugnot", 20, lock)
	if err != nil || len(ps) != 1 {
		t.Fatalf("first turn: %v %v", ps, err)
	}
	if ps[0].Fee != 20 || ps[0].Amount != 104-20 || ps[0].To != alice {
		t.Fatalf("first installment %+v", ps[0])
	}
	c, _ := rt.Claim(pk(1))
	if c.Paid != 104 || c.State != Open {
		t.Fatalf("claim %+v", c)
	}
	// Within the same second nothing more (the recipient meter is dry).
	if ps, _ := rt.PayClaims(now, 0, t0, "ugnot", 20, lock); len(ps) != 0 {
		t.Fatalf("paid from a dry meter: %v", ps)
	}
	// A day later the recipient meter is full (2500): the claim gets 2500 more.
	ps, _ = rt.PayClaims(now+Day, 0, t0, "ugnot", 20, lock)
	if len(ps) != 1 || ps[0].Fee != 0 || ps[0].Amount != 2_500 {
		t.Fatalf("second installment %+v", ps)
	}
	// Then the rest.
	ps, _ = rt.PayClaims(now+3*Day, 0, t0, "ugnot", 20, lock)
	if len(ps) != 1 || ps[0].Amount != 5_000-104-2_500 {
		t.Fatalf("last installment %+v", ps)
	}
	c, _ = rt.Claim(pk(1))
	if c.State != Done || c.Paid != 5_000 {
		t.Fatalf("done %+v", c)
	}
	d := rt.Denom("ugnot")
	if d.Totals.Owed != 0 || d.Totals.Fees != 20 || d.Totals.Paid != 4_980 || rt.Waiting("ugnot") != 0 {
		t.Fatalf("totals %+v waiting %d", d.Totals, rt.Waiting("ugnot"))
	}
	checkClaimTotals(t, rt, "ugnot")
}

// No slivers: a later installment is paid only when both meters hold at least
// min(what the claim still owes, the fee).
func TestClaimNoSlivers(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000)
	mustCredit(t, rt, t0, 1, "ugnot", alice, 5_000, lock)
	// After 12 minutes the recipient meter holds 20 (2500 * 720/86400 = 20.8):
	// the fee, whole.
	ps, _ := rt.PayClaims(t0+720, 0, t0, "ugnot", 20, lock)
	if len(ps) != 1 || ps[0].Fee != 20 || ps[0].Amount != 0 {
		t.Fatalf("fee only: %+v", ps)
	}
	// 5 minutes later the meter holds 8, below the fee: passed over.
	ps, _ = rt.PayClaims(t0+720+300, 0, t0, "ugnot", 20, lock)
	if len(ps) != 0 {
		t.Fatalf("paid a sliver: %+v", ps)
	}
	// Once it holds 20 it pays again.
	ps, _ = rt.PayClaims(t0+720+700, 0, t0, "ugnot", 20, lock)
	if len(ps) != 1 || ps[0].Amount < 20 {
		t.Fatalf("installment: %+v", ps)
	}
}

// A claim's remainder below the fee is paid as soon as the meters hold it.
func TestClaimSmallRemainderNotASliver(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000)
	mustCredit(t, rt, t0, 1, "ugnot", alice, 30, lock)      // fee 20 + 10
	ps, _ := rt.PayClaims(t0+500, 0, t0, "ugnot", 20, lock) // recipient meter 14
	if len(ps) != 0 {
		t.Fatalf("paid with 14 for a fee of 20: %+v", ps)
	}
	// 25 in the meter: the fee whole, and not 5 of the remaining 10 (a sliver
	// after the fee is refused too).
	ps, _ = rt.PayClaims(t0+864, 0, t0, "ugnot", 20, lock)
	if len(ps) != 1 || ps[0].Fee != 20 || ps[0].Amount != 0 {
		t.Fatalf("%+v", ps)
	}
	ps, _ = rt.PayClaims(t0+864+174, 0, t0, "ugnot", 20, lock) // 5 + 5: the remainder exactly
	if len(ps) != 1 || ps[0].Amount != 10 {
		t.Fatalf("remainder %+v", ps)
	}
	c, _ := rt.Claim(pk(1))
	if c.State != Done {
		t.Fatalf("%+v", c)
	}
}

// Recipients are served round-robin, each recipient's oldest claim first; a
// call pays at most n claims and looks at most at 4n recipients.
func TestClaimRoundRobinOldestFirst(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(1_000_000) // cap 100000/day, recipient 25000
	mustCredit(t, rt, t0, 1, "ugnot", alice, 100, lock)
	mustCredit(t, rt, t0, 2, "ugnot", alice, 100, lock)
	mustCredit(t, rt, t0, 3, "ugnot", bob, 100, lock)
	mustCredit(t, rt, t0, 4, "ugnot", carol, 100, lock)
	ps, _ := rt.PayClaims(t0+Day, 0, t0, "ugnot", 3, lock)
	if len(ps) != 3 {
		t.Fatalf("paid %d", len(ps))
	}
	got := []string{}
	for _, p := range ps {
		got = append(got, p.Key)
	}
	// One claim per recipient per round, alice's oldest first.
	seen := map[address]bool{}
	for _, p := range ps {
		if seen[p.To] {
			t.Fatalf("a recipient served twice in one round: %v", got)
		}
		seen[p.To] = true
	}
	for _, p := range ps {
		if p.To == alice && p.Key != pk(1) {
			t.Fatalf("alice's newer claim first: %v", got)
		}
	}
	// The next call serves the one left.
	ps, _ = rt.PayClaims(t0+Day, 0, t0, "ugnot", 3, lock)
	if len(ps) != 1 || ps[0].Key != pk(2) {
		t.Fatalf("second call %+v", ps)
	}
	checkClaimTotals(t, rt, "ugnot")
	if _, err := rt.PayClaims(t0, 0, t0, "ugnot", 0, lock); err == nil {
		t.Fatalf("n = 0")
	}
}

// n is capped at MaxClaims.
func TestClaimAtMostTwenty(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(10_000_000)
	for i := uint64(1); i <= 30; i++ {
		mustCredit(t, rt, t0, i, "ugnot", testutils.TestAddress("r"+string(rune('a'+i))), 50, lock)
	}
	ps, _ := rt.PayClaims(t0+Day, 0, t0, "ugnot", 1000, lock)
	if len(ps) != MaxClaims {
		t.Fatalf("paid %d", len(ps))
	}
}

// The bridge meter bounds the total, the recipient meter each recipient, and
// an unescrowed denom never pays more than the lock holds.
func TestClaimBoundedByMetersAndLock(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000) // cap 10000
	mustCredit(t, rt, t0, 1, "ugnot", alice, 50_000, lock)
	mustCredit(t, rt, t0, 2, "ugnot", bob, 40_000, lock)
	var total int64
	for h := int64(1); h <= 48; h++ {
		ps, _ := rt.PayClaims(t0+h*3600, 0, t0, "ugnot", 20, lock)
		a, f := sumPay(ps)
		total += a + f
		lock -= a + f
	}
	// Two days: at most a full bucket (none at start: empty) plus two days of
	// refill at the cap, i.e. 20000; each recipient at most 2 × 2500.
	if total > 2*10_000 {
		t.Fatalf("paid %d over 2 days", total)
	}
	a, _ := rt.Claim(pk(1))
	b, _ := rt.Claim(pk(2))
	if a.Paid > 5_000 || b.Paid > 5_000 {
		t.Fatalf("a recipient over its meter: %d %d", a.Paid, b.Paid)
	}
	checkClaimTotals(t, rt, "ugnot")

	// A lock that dries up stops payouts without error.
	_, rt2 := newRoute(t)
	mustCredit(t, rt2, t0, 1, "ugnot", alice, 1_000, 1_000)
	ps, _ := rt2.PayClaims(t0+Day, 0, t0, "ugnot", 20, 300)
	a2, f2 := sumPay(ps)
	if a2+f2 != 300 {
		t.Fatalf("paid %d from a lock of 300", a2+f2)
	}
	ps, _ = rt2.PayClaims(t0+2*Day, 0, t0, "ugnot", 20, 0)
	if len(ps) != 0 {
		t.Fatalf("paid from an empty lock")
	}
}

// A payouts flag cleared (a new epoch) empties both meters.
func TestClaimEpochResetsMeters(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000)
	mustCredit(t, rt, t0, 1, "ugnot", alice, 5_000, lock)
	// Two days pass with payouts flagged (nobody claims). The flag clears at
	// t0+2d: epoch 1. A claim right then pays nothing.
	ps, _ := rt.PayClaims(t0+2*Day, 1, t0+2*Day, "ugnot", 20, lock)
	if len(ps) != 0 {
		t.Fatalf("paid right after the epoch: %+v", ps)
	}
	ps, _ = rt.PayClaims(t0+2*Day+3600, 1, t0+2*Day, "ugnot", 20, lock)
	if len(ps) != 1 || ps[0].Fee+ps[0].Amount != 104 {
		t.Fatalf("an hour after the epoch: %+v", ps)
	}
}

// A minted denom's payouts mint vouchers: outstanding grows, no lock applies.
func TestMintClaims(t *testing.T) {
	_, rt := newRoute(t)
	mustCredit(t, rt, t0, 1, "ibc/WETH", alice, 1_000, 0)
	ps, _ := rt.PayClaims(t0+Day, 0, t0, "ibc/WETH", 20, 0) // recipient 1000/day
	a, f := sumPay(ps)
	if a+f != 1_000 || f != 10 {
		t.Fatalf("paid %d fee %d", a, f)
	}
	d := rt.Denom("ibc/WETH")
	if d.Totals.Outstanding != 1_000 || d.Totals.Owed != 0 {
		t.Fatalf("totals %+v", d.Totals)
	}
}

// A randomized run: credits and claims at random times keep the claim
// accounting identities, never pay more than credited, and never exceed the
// two-caps-a-day bound.
func TestClaimsRandomized(t *testing.T) {
	g := &lcg{s: 99}
	recips := []address{alice, bob, carol, collector}
	for trial := 0; trial < 5; trial++ {
		_, rt := newRoute(t)
		lock := int64(200_000)
		now := t0
		var seq uint64
		var paidTotal int64
		for step := 0; step < 120; step++ {
			now += g.next(7200)
			if g.next(2) == 0 {
				seq++
				amt := g.next(30_000) + 1
				_, err := rt.Credit(now, 10, 0, pk(seq), "ugnot", recips[g.next(4)], amt, ByPacket, "", lock)
				if err != nil {
					t.Fatal(err)
				}
			} else {
				ps, err := rt.PayClaims(now, 0, t0, "ugnot", int(g.next(25)+1), lock)
				if err != nil {
					t.Fatal(err)
				}
				a, f := sumPay(ps)
				if a+f > lock {
					t.Fatalf("paid %d from a lock of %d", a+f, lock)
				}
				lock -= a + f
				paidTotal += a + f
			}
			checkClaimTotals(t, rt, "ugnot")
		}
		d := rt.Denom("ugnot")
		if paidTotal > d.Totals.Credited {
			t.Fatalf("paid %d of %d credited", paidTotal, d.Totals.Credited)
		}
		days := (now - t0 + Day - 1) / Day
		if paidTotal > (days+1)*20_000 {
			t.Fatalf("paid %d in %d days", paidTotal, days)
		}
	}
}

// A minted denom enabled over vouchers already in circulation counts them
// against its supply cap from the start (Codex review #8).
func TestMintStartsAtExistingSupply(t *testing.T) {
	r := NewRegistry()
	rt, _ := r.Enroll("ethereum-1", collector, t0, 1)
	if err := rt.SetDenom("ibc/WETH", mintCfg(), t0, 0, -1); err == nil {
		t.Fatalf("negative supply")
	}
	supplyCap := mintCfg().SupplyCap
	if err := rt.SetDenom("ibc/WETH", mintCfg(), t0, 0, supplyCap-100); err != nil {
		t.Fatal(err)
	}
	if err := rt.CheckCredit("ibc/WETH", 101); err == nil {
		t.Fatalf("admitted past the cap over the existing supply")
	}
	if err := rt.CheckCredit("ibc/WETH", 100); err != nil {
		t.Fatal(err)
	}
	// A configuration change keeps the accounting.
	if err := rt.SetDenom("ibc/WETH", mintCfg(), t0, 0, 0); err != nil || rt.Denom("ibc/WETH").Totals.Outstanding != supplyCap-100 {
		t.Fatalf("%v", err)
	}
	// An unescrowed denom has no supply.
	rt.SetDenom("ugnot", gnot(), t0, 0, 5)
	if rt.Denom("ugnot").Totals.Outstanding != 0 {
		t.Fatalf("outstanding on an unescrowed denom")
	}
}

func sendRec7(seq uint64, amount int64) SendRecord {
	rec := sendRec(seq, "ibc/WETH", KindMint, amount)
	rec.Key = PacketKey("ethereum-7", seq)
	rec.Fee = 0
	return rec
}

// A claim's fee is locked when it is credited: a fee raised afterwards never
// applies to it, neither as its first installment nor as its later minimum
// installment (docs-vs-code review round 2 #6).
func TestClaimFeeLockedAtCredit(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000) // a recipient 2500 a day
	mustCredit(t, rt, t0, 1, "ugnot", alice, 3_000, lock)
	raised := gnot()
	raised.Fee = 2_000 // the ceiling is CapFloor/4 = 2500
	if err := rt.SetDenom("ugnot", raised, t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	mustCredit(t, rt, t0, 2, "ugnot", bob, 3_000, lock)
	ps, err := rt.PayClaims(t0+Day, 0, t0, "ugnot", 2, lock)
	if err != nil || len(ps) != 2 {
		t.Fatalf("%v %+v", err, ps)
	}
	for _, p := range ps {
		want := int64(20) // credited before the change
		if p.To == bob {
			want = 2_000 // credited after it
		}
		if p.Fee != want {
			t.Fatalf("%s paid fee %d, want %d", p.To, p.Fee, want)
		}
	}
	c, _ := rt.Claim(pk(1))
	if c.Fee != 20 || c.Paid != 2_500 {
		t.Fatalf("%+v", c)
	}
	// Its last 500 is paid as an installment of at least its own fee (20),
	// not the raised one: an hour's refill (104) is enough.
	ps, _ = rt.PayClaims(t0+Day+3600, 0, t0, "ugnot", 1, lock)
	if len(ps) != 1 || ps[0].To != alice || ps[0].Fee != 0 {
		t.Fatalf("%+v", ps)
	}
}

// A claim's fee is the lower of its locked fee and the current one: lowering
// the cap floor and the fee after a credit never strands the claim, unpaid,
// paid in part, or withheld and restored (Codex round 22 #1).
func TestClaimFeeFollowsACut(t *testing.T) {
	raised := gnot()
	raised.CapFloor, raised.Fee = 100_000, 20_000
	lock := int64(100_000)
	setup := func() *Route {
		_, rt := newRoute(t)
		if err := rt.SetDenom("ugnot", raised, t0, 0, 0); err != nil {
			t.Fatal(err)
		}
		return rt
	}
	cut := func(rt *Route) {
		if err := rt.SetDenom("ugnot", gnot(), t0, 0, 0); err != nil {
			t.Fatal(err)
		}
	}

	// Unpaid: its locked fee (20,000) is above what a recipient meter can now
	// hold (2,500); it is paid with the current fee.
	rt := setup()
	mustCredit(t, rt, t0, 1, "ugnot", alice, 30_000, lock)
	cut(rt)
	ps, _ := rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, lock)
	if len(ps) != 1 || ps[0].Fee != 20 || ps[0].Amount != 2_480 {
		t.Fatalf("unpaid: %+v", ps)
	}

	// Paid in part: its minimum installment follows the cut too.
	rt = setup()
	mustCredit(t, rt, t0, 1, "ugnot", alice, 30_000, lock)
	ps, _ = rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, lock)
	if len(ps) != 1 || ps[0].Fee != 20_000 || ps[0].Amount != 0 { // the fee alone: no sliver after it
		t.Fatalf("first installment: %+v", ps)
	}
	cut(rt)
	ps, _ = rt.PayClaims(t0+2*Day, 0, t0, "ugnot", 1, lock)
	if len(ps) != 1 || ps[0].Fee != 0 || ps[0].Amount != 2_500 {
		t.Fatalf("paid in part: %+v", ps)
	}

	// Withheld, then restored after the cut.
	rt = setup()
	mustCredit(t, rt, t0, 1, "ugnot", alice, 30_000, lock)
	if err := rt.Void([]string{pk(1)}, false, "inc"); err != nil {
		t.Fatal(err)
	}
	cut(rt)
	if err := rt.Restore([]string{pk(1)}, t0, 0); err != nil {
		t.Fatal(err)
	}
	ps, _ = rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, lock)
	if len(ps) != 1 || ps[0].Fee != 20 {
		t.Fatalf("restored: %+v", ps)
	}
}

// A fee cut a payout turn has seen is kept: a later raise never brings a
// claim's fee back up (docs-vs-code review round 4 #1).
func TestClaimFeeCutKept(t *testing.T) {
	_, rt := newRoute(t)
	lock := int64(100_000) // a recipient 2500 a day
	mustCredit(t, rt, t0, 1, "ugnot", alice, 3_000, lock)
	if ps, _ := rt.PayClaims(t0+Day, 0, t0, "ugnot", 1, lock); len(ps) != 1 || ps[0].Fee != 20 {
		t.Fatalf("first installment: %+v", ps)
	}
	setFee := func(fee int64) {
		c := gnot()
		c.Fee = fee
		if err := rt.SetDenom("ugnot", c, t0, 0, 0); err != nil {
			t.Fatal(err)
		}
	}
	setFee(2)
	// A turn a second later pays nothing (the recipient meter is dry) but
	// sees the cut.
	if ps, _ := rt.PayClaims(t0+Day+1, 0, t0, "ugnot", 1, lock); len(ps) != 0 {
		t.Fatalf("paid with a dry meter: %+v", ps)
	}
	setFee(10)
	// 200 seconds refill about 5: enough for an installment of at least the
	// kept fee (2), not the raised one (10).
	ps, _ := rt.PayClaims(t0+Day+201, 0, t0, "ugnot", 1, lock)
	if len(ps) != 1 || ps[0].Amount < 2 || ps[0].Amount >= 10 {
		t.Fatalf("after the raise: %+v", ps)
	}
	if c, _ := rt.Claim(pk(1)); c.Fee != 2 {
		t.Fatalf("fee %d", c.Fee)
	}
}

// The index of fee collectors counts the routes each collects for (design
// review r8 #2): it stays set while any route still names the address.
func TestFeeCollectorIndex(t *testing.T) {
	r, _ := newRoute(t)
	if _, err := r.Enroll("ethereum-2", collector, t0, 1); err != nil {
		t.Fatal(err)
	}
	rd := Reader{r: r}
	if !rd.IsFeeCollector(collector) || rd.IsFeeCollector(bob) {
		t.Fatalf("index after two enrolments")
	}
	if err := r.SetFeeCollector("ethereum-1", bob); err != nil {
		t.Fatal(err)
	}
	if !rd.IsFeeCollector(collector) || !rd.IsFeeCollector(bob) {
		t.Fatalf("index after one change")
	}
	if err := r.SetFeeCollector("ethereum-2", bob); err != nil {
		t.Fatal(err)
	}
	if rd.IsFeeCollector(collector) || !rd.IsFeeCollector(bob) || r.Route("ethereum-2").FeeCollector != bob {
		t.Fatalf("index after both changed")
	}
	if r.SetFeeCollector("ethereum-9", bob) == nil || r.SetFeeCollector("ethereum-1", "bad") == nil {
		t.Fatalf("set a collector on no route, or an invalid one")
	}
	if !rd.IsFeeCollector(bob) || (Reader{}).IsFeeCollector(bob) {
		t.Fatalf("a refused change moved the index, or an invalid reader read it")
	}
}

// A cap change never applies to the time before it (main ADR design review
// r2 #2): a meter idle 7 days at 24 a day, raised to 2400, holds 24 at the
// change, then refills at 2400; a refill that first sees the new cap
// without a settlement still refills the idle time at the old one; a cut
// clips the level to the new cap.
func TestMeterCapChangeNotBackdated(t *testing.T) {
	m := NewMeter(0, 0)
	m.Refill(0, 24, 24, 0, 0)
	m.Refill(7*Day, 24, 24, 0, 0) // settled at the old cap
	m.Refill(7*Day, 2400, 2400, 0, 0)
	if m.Level != 24 {
		t.Fatalf("at the change: %d", m.Level)
	}
	m.Refill(7*Day+Day/2, 2400, 2400, 0, 0)
	if m.Level != 1224 {
		t.Fatalf("half a day at the new cap: %d", m.Level)
	}
	// Unsettled: the first refill to see the new cap refills the idle week
	// at the old one.
	u := NewMeter(0, 0)
	u.Refill(0, 24, 24, 0, 0)
	u.Refill(7*Day, 2400, 2400, 0, 0)
	if u.Level != 24 {
		t.Fatalf("backdated: %d", u.Level)
	}
	// A cut: the level comes down to the new cap at once.
	c := NewMeter(0, 0)
	c.Refill(0, 2400, 2400, 0, 0)
	c.Refill(Day, 24, 24, 0, 0)
	if c.Level != 24 {
		t.Fatalf("after a cut: %d", c.Level)
	}
	c.Refill(Day+Day/2, 24, 24, 0, 0)
	if c.Level != 24 {
		t.Fatalf("after a cut, full: %d", c.Level)
	}
}

// A governed reconfiguration settles the denom's meters at the old caps
// first (Route.Reconfigure).
func TestReconfigureSettlesMeters(t *testing.T) {
	_, rt := newRoute(t)
	d := rt.Denom("ugnot")
	cfg := d.Config
	d.refundMeter.Refill(t0, cfg.RefundCap, cfg.RefundCap, 0, 0)
	d.refundMeter.Take(d.refundMeter.Level) // empty, at the old cap
	old := cfg.RefundCap
	cfg.RefundCap = old * 100
	if err := rt.Reconfigure("ugnot", cfg, t0+7*Day, 0, t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if d.refundMeter.Level != old {
		t.Fatalf("the refund meter after a week idle, cap raised: %d, not the old cap %d", d.refundMeter.Level, old)
	}
	d.refundMeter.Refill(t0+7*Day+Day/2, cfg.RefundCap, cfg.RefundCap, 0, 0)
	if d.refundMeter.Level != old+cfg.RefundCap/2 {
		t.Fatalf("half a day later: %d", d.refundMeter.Level)
	}
	// Refused: nothing changes, the meters included.
	before := d.refundMeter
	bad := cfg
	bad.Kind = KindMint
	if rt.Reconfigure("ugnot", bad, t0+9*Day, 0, t0, 0, 0) == nil || d.refundMeter != before {
		t.Fatalf("a refused reconfiguration changed the meters")
	}
}

// A recipient meter starts at the cap in effect when it is made (code review
// r60 #2): a claim credited at a 4000-a-day cap, the cap raised to
// 4,000,000 a week later, the claim's first payout an hour after that pays
// no more than the old recipient cap (1000), not the backdated new one.
func TestRecipientMeterNotBackdated(t *testing.T) {
	_, rt := newRoute(t)
	cfg := rt.Denom("ibc/WETH").Config
	if err := rt.Reconfigure("ibc/WETH", cfg, t0, 0, t0, 0, 0); err != nil { // the meters see the cap
		t.Fatal(err)
	}
	mustCredit(t, rt, t0, 5, "ibc/WETH", alice, 90_000, big)
	cfg.CapFloor, cfg.SupplyCap = 4_000_000, 10_000_000
	if err := rt.Reconfigure("ibc/WETH", cfg, t0+7*Day, 0, t0, 0, 0); err != nil {
		t.Fatal(err)
	}
	rt.PayClaims(t0+7*Day+3600, 0, t0, "ibc/WETH", 1, big)
	c, _ := rt.Claim(pk(5))
	if c.Paid == 0 || c.Paid > 1_000 {
		t.Fatalf("paid %d: the recipient meter backdated the raise", c.Paid)
	}
}
