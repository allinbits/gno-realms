package controls

import (
	"testing"
)

// lcg is a small deterministic pseudo-random sequence for table-driven
// fuzzing (Gno has no math/rand in /p/ tests that is stable across versions).
type lcg struct{ s uint64 }

func (g *lcg) next(n int64) int64 {
	g.s = g.s*6364136223846793005 + 1442695040888963407
	if n <= 0 {
		return 0
	}
	return int64((g.s >> 33) % uint64(n))
}

// Refilling in any pieces over a day adds exactly the rate (up to the
// ceiling): the fractional remainder is carried.
func TestMeterRefillSumsToRate(t *testing.T) {
	g := &lcg{s: 7}
	rates := []uint256{1, 7, 86399, 86400, 86401, 1_000_000, 10_000_000_000, 123_456_789_123}
	for _, rate := range rates {
		for trial := 0; trial < 20; trial++ {
			m := NewMeter(1000, 0)
			now := int64(1000)
			for now < 1000+Day {
				step := g.next(5000) + 1
				if now+step > 1000+Day {
					step = 1000 + Day - now
				}
				now += step
				m.Refill(now, rate, rate*2, 0, 0)
			}
			if m.Level != rate {
				t.Fatalf("rate %d trial %d: level %d after a day in pieces", rate, trial, m.Level)
			}
		}
	}
}

func TestMeterCeilingAndCatchUp(t *testing.T) {
	m := NewMeter(0, 0)
	m.Refill(Day/2, 1000, 1000, 0, 0)
	if m.Level != 500 {
		t.Fatalf("half a day: %d", m.Level)
	}
	m.Refill(10*Day, 1000, 1000, 0, 0)
	if m.Level != 1000 {
		t.Fatalf("ceiling: %d", m.Level)
	}
	// Time going backwards refills nothing.
	m.Take(400)
	m.Refill(5*Day, 1000, 1000, 0, 0)
	if m.Level != 600 {
		t.Fatalf("backwards: %d", m.Level)
	}
	// A ceiling below the level brings it down (the cap fell).
	m.Refill(10*Day, 1000, 250, 0, 0)
	if m.Level != 250 {
		t.Fatalf("lower ceiling: %d", m.Level)
	}
	// Take never goes below zero.
	m.Take(10_000)
	if m.Level != 0 {
		t.Fatalf("take: %d", m.Level)
	}
}

// A new payouts epoch empties the meter as of the epoch's start: it refills
// from there, never from its old level.
func TestMeterEpochEmpties(t *testing.T) {
	m := NewMeter(0, 0)
	m.Refill(Day, 1000, 1000, 0, 0)
	if m.Level != 1000 {
		t.Fatalf("full: %d", m.Level)
	}
	m.Refill(Day+Day/4, 1000, 1000, 1, Day)
	if m.Level != 250 || m.Epoch != 1 {
		t.Fatalf("after the epoch: level %d epoch %d", m.Level, m.Epoch)
	}
	// The same epoch again does not empty it.
	m.Refill(Day+Day/2, 1000, 1000, 1, Day)
	if m.Level != 500 {
		t.Fatalf("same epoch: %d", m.Level)
	}
}

// Within any 24 hours at most two ceilings leave: a full bucket plus a day of
// refill (ADR pr6375 §7.1). Drain greedily at random instants and check every
// window of a day.
func TestMeterTwoCapsPerDay(t *testing.T) {
	g := &lcg{s: 42}
	const rate = uint256(1_000_000)
	m := NewMeter(0, 0)
	m.Refill(Day, rate, rate, 0, 0) // full at t = Day
	type draw struct {
		at     int64
		amount uint256
	}
	var draws []draw
	now := Day
	for now < 6*Day {
		now += g.next(3600) + 1
		m.Refill(now, rate, rate, 0, 0)
		amt := m.Level
		if g.next(3) == 0 {
			amt = m.Level / 2
		}
		m.Take(amt)
		draws = append(draws, draw{now, amt})
	}
	for i := range draws {
		var sum uint256
		for j := i; j < len(draws) && draws[j].at < draws[i].at+Day; j++ {
			sum += draws[j].amount
		}
		if sum > 2*rate {
			t.Fatalf("window from %d drew %d > 2 caps", draws[i].at, sum)
		}
	}
}

// A cap past the int64 maximum never overflows a refill: a nearly full
// bucket, a partial refill and a long idle period all saturate at the cap
// (Codex review #16), and so does the largest cap of all.
func TestMeterNearMaxCap(t *testing.T) {
	const ceil = uint256(60_000_000_000_000_000_000)
	m := NewMeter(0, 0)
	m.Level = ceil - 1
	m.Refill(Day, ceil, ceil, 0, 0) // a full day on a nearly full bucket
	if m.Level != ceil {
		t.Fatalf("nearly full + a day: %d", m.Level)
	}
	m.Take(ceil / 2)
	m.Refill(Day+Day/4, ceil, ceil, 0, 0) // a quarter day: not full yet
	if want := ceil/2 + ceil/4; m.Level != want {
		t.Fatalf("partial refill: %d, want %d", m.Level, want)
	}
	m.Refill(100*Day, ceil, ceil, 0, 0) // idle for long
	if m.Level != ceil {
		t.Fatalf("idle: %d", m.Level)
	}
	// The largest rate and ceiling: the whole days' refill would overflow,
	// which fills the meter.
	big := NewMeter(0, 0)
	big.Level = maxAmount - 5
	big.Refill(Day, maxAmount, maxAmount, 0, 0)
	if big.Level != maxAmount {
		t.Fatalf("max: %d", big.Level)
	}
	big.Take(1000)
	big.Refill(2*Day, maxAmount, maxAmount, 0, 0)
	if big.Level != maxAmount {
		t.Fatalf("max after a day: %d", big.Level)
	}
}
