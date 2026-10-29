package decisions

import (
	"strings"
	"testing"
)

func TestLedger(t *testing.T) {
	var l Ledger
	if l.Get(1) != nil || l.Last() != 0 || !strings.Contains(l.Page(), "No decision yet") {
		t.Fatalf("an empty ledger")
	}
	now := int64(1_000_000)
	a := l.Record("set cap floor", "cap floor 12000 GNOT", 12, now-10, now, now+Delay)
	b := l.Record("set cap floor", "cap floor 9000 GNOT", 9, now-10, now, now)
	if a.ID != 1 || b.ID != 2 || l.Last() != 2 || l.Size() != 2 {
		t.Fatalf("numbering %d %d %d", a.ID, b.ID, l.Last())
	}
	if !a.Pending() || !a.Queued() || b.Queued() || !b.Pending() {
		t.Fatalf("states: a queued %v b queued %v", a.Queued(), b.Queued())
	}
	l.Apply(b, now, "at once: a lowering")
	if b.State() != "applied" || b.Pending() {
		t.Fatalf("b %s", b.State())
	}
	// not due yet, then due
	if _, err := l.Due(1, now+Delay-1); err == nil || !strings.Contains(err.Error(), "is due at") {
		t.Fatalf("due early: %v", err)
	}
	if _, err := l.Due(2, now); err == nil || !strings.Contains(err.Error(), "applied, not pending") {
		t.Fatalf("due of an applied one: %v", err)
	}
	if _, err := l.Due(3, now); err == nil || !strings.Contains(err.Error(), "no decision 3") {
		t.Fatalf("due of none: %v", err)
	}
	d, err := l.Due(1, now+Delay)
	if err != nil || d != a {
		t.Fatalf("due: %v", err)
	}
	// cancel
	c := l.Record("set maximum", "maximum 30000 GNOT", 30, now, now, now+Delay)
	if _, err := l.Cancel(2, now); err == nil {
		t.Fatalf("cancelled an applied one")
	}
	if _, err := l.Cancel(c.ID, now+1); err != nil || c.State() != "cancelled" || c.Pending() {
		t.Fatalf("cancel: %v %s", err, c.State())
	}
	s := l.Record("unpause", "payouts on hlgnot", nil, now, now, now)
	l.Spend(s, "spent: nothing to clear")
	if s.State() != "spent" || s.Pending() {
		t.Fatalf("spent %s", s.State())
	}
	// the deadline
	if Expired(now, now+Deadline) != nil || Expired(now, now+Deadline+1) == nil {
		t.Fatalf("deadline")
	}
	// the clock factor divides the delays: 1 on mainnet (what §8.3's check wants), shown on the pages
	if Factor != 1 || Delay != 7*Day/Factor || Deadline != 14*Day/Factor || Delay != 604800 || Deadline != 1209600 {
		t.Fatalf("clocks: factor %d delay %d deadline %d", Factor, Delay, Deadline)
	}
	if Clocks() != "clock factor 1 (1 on mainnet; a devnet build is compiled with 8): the 7-day delay is 604800 s and the 14-day deadline 1209600 s of block time" || ClocksJSON() != "{\"factor\":1,\"delay\":604800,\"deadline\":1209600}" {
		t.Fatalf("clocks text: %s %s", Clocks(), ClocksJSON())
	}
	// the page: per kind, pending and executed
	p := l.Page()
	for _, want := range []string{"### set cap floor", "pending:\n- #1 pending: cap floor 12000 GNOT (recorded 1000000, due 1604800)",
		"executed:\n- #2 applied: cap floor 9000 GNOT (recorded 1000000, applied 1000000) — at once: a lowering",
		"### set maximum", "- #3 cancelled:", "### unpause", "- #4 spent:", "spent: nothing to clear"} {
		if !strings.Contains(p, want) {
			t.Fatalf("page lacks %q:\n%s", want, p)
		}
	}
	j := l.JSON()
	if !strings.HasPrefix(j, "[{\"id\":1,\"kind\":\"set cap floor\"") || !strings.Contains(j, "\"state\":\"spent\"") {
		t.Fatalf("json: %s", j)
	}
	n := 0
	l.Each(func(d *Decision) bool { n++; return false })
	if n != 4 {
		t.Fatalf("each saw %d", n)
	}
}

func TestPageCap(t *testing.T) {
	var l Ledger
	for i := 0; i < PageMax+5; i++ {
		d := l.Record("void", "ids …", nil, 1, 2, 2)
		l.Apply(d, 3, "")
	}
	p := l.Page()
	if strings.Contains(p, "#1 applied") || !strings.Contains(p, "#"+itoa(int64(PageMax+5))+" applied") || !strings.Contains(p, "#6 applied") {
		t.Fatalf("the page should show the last %d executed:\n%s", PageMax, p)
	}
}

// TestGovernor (M1k): the rule every bridge realm reads — GovDAO's proxy decides when no governor was compiled or
// once the governor yielded, the governor alone before — and the one page line and json the six realms show of it.
func TestGovernor(t *testing.T) {
	g := address("g1dpkz6em0wejhymn0wf047h6lta047h6lvxn4gx")
	if !DAOGoverns("", 0) || !DAOGoverns("", 7) || DAOGoverns(g, 0) || !DAOGoverns(g, 7) {
		t.Fatalf("who governs: none %v %v, g %v %v", DAOGoverns("", 0), DAOGoverns("", 7), DAOGoverns(g, 0), DAOGoverns(g, 7))
	}
	if GovernorLine("", 0) != "governor: gno.land/r/gov/dao from the first block (no governor was compiled)" {
		t.Fatalf("no governor: %s", GovernorLine("", 0))
	}
	if GovernorLine(g, 0) != "governor: "+string(g)+" (until the yield) — it alone decides, by Govern from its own key, and gno.land/r/gov/dao's proposals are refused" {
		t.Fatalf("until the yield: %s", GovernorLine(g, 0))
	}
	if GovernorLine(g, 123_456) != "governor: gno.land/r/gov/dao since height 123456 ("+string(g)+" yielded)" {
		t.Fatalf("yielded: %s", GovernorLine(g, 123_456))
	}
	if GovernorJSON(g, 0) != "\"governor\":\""+string(g)+"\",\"yielded\":0" || GovernorJSON("", 0) != "\"governor\":\"\",\"yielded\":0" || GovernorJSON(g, 9) != "\"governor\":\""+string(g)+"\",\"yielded\":9" {
		t.Fatalf("json: %s", GovernorJSON(g, 0))
	}
}

func TestCopyAndFind(t *testing.T) {
	var l Ledger
	type params struct{ n int }
	p := &params{n: 1}
	d := l.Record("kind", "text", p, 1, 2, 2+Delay)
	c, ok := l.Find(d.ID)
	if !ok || c.ID != d.ID || c.Kind != "kind" || c.Params != nil || c.Due != 2+Delay {
		t.Fatalf("find: %v %+v", ok, c)
	}
	c.Note = "changed"
	if d.Note == "changed" {
		t.Fatalf("Copy aliases the stored decision")
	}
	if _, ok := l.Find(99); ok {
		t.Fatalf("found a decision that does not exist")
	}
	if UnpauseDelay != Day/Factor || Delay != 7*UnpauseDelay {
		t.Fatalf("delays %d %d", UnpauseDelay, Delay)
	}
}
