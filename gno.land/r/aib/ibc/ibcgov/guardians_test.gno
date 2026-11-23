package ibcgov

import (
	"testing"

	"gno.land/p/aib/decisions/v0"
)

// Each seat generation keeps its own end: a stale flag of an earlier
// generation reads when its own key left, not when the seat's latest key
// did, and a generation's record goes with the last of its entries (Codex
// round 14).
func TestSeatGenerationEnds(t *testing.T) {
	g := testRoute("gens")
	put := func(k string, at int64) *flag {
		f := &flag{seat: 2, gen: g.seatGen[2], at: at}
		g.flags.Set(k, f)
		g.seatFlags[2]++
		return f
	}
	a := put("r1|sends|2", 1)
	b := put("r2|sends|2", 1)
	clearSeat(g, 2, 100) // the first key leaves at 100
	c := put("r3|sends|2", 150)
	clearSeat(g, 2, 200) // the second at 200
	clearSeat(g, 2, 300) // an empty generation keeps no record

	if g.endedAt(a) != 100 || g.endedAt(b) != 100 || g.endedAt(c) != 200 {
		t.Fatalf("ends: %d %d %d", g.endedAt(a), g.endedAt(b), g.endedAt(c))
	}
	if g.genEnds.Size() != 2 {
		t.Fatalf("records: %d", g.genEnds.Size())
	}
	pruneFlag(g, "r1|sends|2", a)
	if g.endedAt(b) != 100 || g.genEnds.Size() != 2 {
		t.Fatalf("after one entry of the first generation: %d, %d records", g.endedAt(b), g.genEnds.Size())
	}
	pruneFlag(g, "r2|sends|2", b)
	pruneFlag(g, "r3|sends|2", c)
	if g.genEnds.Size() != 0 || g.flags.Size() != 0 {
		t.Fatalf("left: %d records, %d entries", g.genEnds.Size(), g.flags.Size())
	}
}

// A PruneFlags call that reaches the end of the entries before its budget
// runs out starts the next call over from the first entry, so a stale entry
// keyed before where it stopped is found at once, not after an empty call
// (review of #92).
func TestPruneFlagsStartsOverAtTheEnd(cur realm, t *testing.T) {
	g := testRoute("prune")
	put := func(k string) {
		g.flags.Set(k, &flag{seat: 3, gen: g.seatGen[3], at: 1})
		g.seatFlags[3]++
	}
	put("r5|sends|3")
	put("r6|sends|3")
	clearSeat(g, 3, 100)
	if n := PruneFlags(cross(cur), g.key, 16); n != 2 || g.pruneAfter != "" {
		t.Fatalf("first pass: %d removed, cursor %q", n, g.pruneAfter)
	}
	put("r1|sends|3") // before where the first pass stopped
	clearSeat(g, 3, 200)
	if n := PruneFlags(cross(cur), g.key, 16); n != 1 {
		t.Fatalf("second pass: %d removed", n)
	}
	// A call whose budget ends before the entries do resumes after them.
	put("r2|sends|3")
	put("r3|sends|3")
	clearSeat(g, 3, 300)
	if n := PruneFlags(cross(cur), g.key, 1); n != 1 || g.pruneAfter != "r2|sends|3" {
		t.Fatalf("a bounded pass: %d removed, cursor %q", n, g.pruneAfter)
	}
	// The last entry, at exactly the budget: the walk reached the end, so
	// the next call starts over (review of #92, round 2).
	if n := PruneFlags(cross(cur), g.key, 1); n != 1 || g.flags.Size() != 0 || g.pruneAfter != "" {
		t.Fatalf("the rest: %d removed, %d left, cursor %q", n, g.flags.Size(), g.pruneAfter)
	}
	put("r4|sends|3")
	put("r7|sends|3")
	clearSeat(g, 3, 400)
	if n := PruneFlags(cross(cur), g.key, 2); n != 2 || g.pruneAfter != "" {
		t.Fatalf("two entries, a budget of two: %d removed, cursor %q", n, g.pruneAfter)
	}
	put("r0|sends|3")
	clearSeat(g, 3, 500)
	if n := PruneFlags(cross(cur), g.key, 2); n != 1 {
		t.Fatalf("an entry before the last walk's end: %d removed", n)
	}
}

// testRoute makes a bare route record for the unit tests.
func testRoute(key string) *routeGov {
	g := &routeGov{key: key, inc: 1, enrolled: true}
	routes.Set(key, g)
	return g
}

// Pruning is per route: route A's stale flags are never walked by route B's
// prune, and each keeps its own cursor (ADR 0007 §1).
func TestPruneFlagsPerRoute(cur realm, t *testing.T) {
	a, b := testRoute("route-a"), testRoute("route-b")
	put := func(g *routeGov, k string) {
		g.flags.Set(k, &flag{seat: 1, gen: g.seatGen[1], at: 1})
		g.seatFlags[1]++
	}
	for i := 0; i < 10; i++ {
		put(a, "route-a|sends|"+string(rune('a'+i)))
	}
	put(b, "route-b|sends|1")
	clearSeat(a, 1, 100)
	clearSeat(b, 1, 100)
	if n := PruneFlags(cross(cur), "route-b", 1); n != 1 || b.flags.Size() != 0 || b.genEnds.Size() != 0 {
		t.Fatalf("route B: %d removed, %d left", n, b.flags.Size())
	}
	if a.flags.Size() != 10 || a.pruneAfter != "" {
		t.Fatalf("route A touched: %d left, cursor %q", a.flags.Size(), a.pruneAfter)
	}
}

// The global hold counters (ADR 0007 §6): some route is held exactly while
// a route flags or lingers; a global hold keeps its start across routes
// holding without a gap, and a new one starts after a gap.
func TestGlobalHoldCounters(t *testing.T) {
	routesFlagging, lingerEnd, globalHeldSince = 0, 0, 0
	a, b := testRoute("hold-a"), testRoute("hold-b")
	flagOn := func(g *routeGov, t0 int64) {
		g.seatFlags[0], g.seatFlags[1] = 1, 1
		updateHold(g, t0)
	}
	flagOff := func(g *routeGov, t0 int64) {
		g.seatFlags[0], g.seatFlags[1] = 0, 0
		updateHold(g, t0)
	}
	flagOn(a, 100)
	if !anyHeldAt(100) || globalHeldSince != 100 || routesFlagging != 1 {
		t.Fatalf("A holds: %v since %d, %d flagging", anyHeldAt(100), globalHeldSince, routesFlagging)
	}
	flagOff(a, 200) // A lingers to 200 + holdLinger
	flagOn(b, 210)  // B starts within A's linger: the same global hold
	if globalHeldSince != 100 || routesFlagging != 1 {
		t.Fatalf("B within A's linger: since %d, %d flagging", globalHeldSince, routesFlagging)
	}
	flagOff(b, 300)
	end := 300 + holdLinger
	if !anyHeldAt(end-1) || anyHeldAt(end) {
		t.Fatalf("the later linger: held before %d %v, at it %v", end, anyHeldAt(end-1), anyHeldAt(end))
	}
	flagOn(a, end+5) // after the gap: a new global hold
	if globalHeldSince != end+5 {
		t.Fatalf("a new global hold since %d, not %d", globalHeldSince, end+5)
	}
	flagOff(a, end+10)
	routesFlagging, lingerEnd, globalHeldSince = 0, 0, 0
}

// A decision recorded for a route key before its record exists counts
// among that incarnation's pending decisions: the record it later gets
// cannot be dropped while it is pending (ADR 0007 §5).
func TestPendingCountedBeforeRecord(t *testing.T) {
	sc := routeScope("pend-key") // no record yet: the first incarnation
	sc.take(1_000_001)
	g := &routeGov{key: "pend-key", inc: 1}
	routes.Set(g.key, g)
	if r := checkDrop(g, 0, 0); r != "route pend-key has pending decisions" {
		t.Fatalf("a decision recorded before the record: %q", r)
	}
	resolve(&decisions.Decision{ID: 1_000_001, Spent: true})
	if r := checkDrop(g, 0, 0); r != "" {
		t.Fatalf("once it is spent: %q", r)
	}
}
