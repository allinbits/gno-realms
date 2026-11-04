package ibcgov

import "testing"

// Each seat generation keeps its own end: a stale flag of an earlier
// generation reads when its own key left, not when the seat's latest key
// did, and a generation's record goes with the last of its entries (Codex
// round 14).
func TestSeatGenerationEnds(t *testing.T) {
	put := func(k string, at int64) *flag {
		f := &flag{seat: 2, gen: seatGen[2], at: at}
		flags.Set(k, f)
		seatFlags[2]++
		return f
	}
	a := put("r1|sends|2", 1)
	b := put("r2|sends|2", 1)
	clearSeat(2, 100) // the first key leaves at 100
	c := put("r3|sends|2", 150)
	clearSeat(2, 200) // the second at 200
	clearSeat(2, 300) // an empty generation keeps no record

	if a.endedAt() != 100 || b.endedAt() != 100 || c.endedAt() != 200 {
		t.Fatalf("ends: %d %d %d", a.endedAt(), b.endedAt(), c.endedAt())
	}
	if genEnds.Size() != 2 {
		t.Fatalf("records: %d", genEnds.Size())
	}
	pruneFlag("r1|sends|2", a)
	if b.endedAt() != 100 || genEnds.Size() != 2 {
		t.Fatalf("after one entry of the first generation: %d, %d records", b.endedAt(), genEnds.Size())
	}
	pruneFlag("r2|sends|2", b)
	pruneFlag("r3|sends|2", c)
	if genEnds.Size() != 0 || flags.Size() != 0 {
		t.Fatalf("left: %d records, %d entries", genEnds.Size(), flags.Size())
	}
}

// A PruneFlags call that reaches the end of the entries before its budget
// runs out starts the next call over from the first entry, so a stale entry
// keyed before where it stopped is found at once, not after an empty call
// (review of #92).
func TestPruneFlagsStartsOverAtTheEnd(cur realm, t *testing.T) {
	put := func(k string) {
		flags.Set(k, &flag{seat: 3, gen: seatGen[3], at: 1})
		seatFlags[3]++
	}
	put("r5|sends|3")
	put("r6|sends|3")
	clearSeat(3, 100)
	if n := PruneFlags(cross(cur), 16); n != 2 || pruneAfter != "" {
		t.Fatalf("first pass: %d removed, cursor %q", n, pruneAfter)
	}
	put("r1|sends|3") // before where the first pass stopped
	clearSeat(3, 200)
	if n := PruneFlags(cross(cur), 16); n != 1 {
		t.Fatalf("second pass: %d removed", n)
	}
	// A call whose budget ends before the entries do resumes after them.
	put("r2|sends|3")
	put("r3|sends|3")
	clearSeat(3, 300)
	if n := PruneFlags(cross(cur), 1); n != 1 || pruneAfter != "r2|sends|3" {
		t.Fatalf("a bounded pass: %d removed, cursor %q", n, pruneAfter)
	}
	if n := PruneFlags(cross(cur), 1); n != 1 || flags.Size() != 0 {
		t.Fatalf("the rest: %d removed, %d left", n, flags.Size())
	}
}
