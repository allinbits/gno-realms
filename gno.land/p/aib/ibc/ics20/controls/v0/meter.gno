package controls

import "math/overflow"

// Meter is a token bucket: a level that refills continuously at a rate per
// day up to a ceiling, with no midnight reset, so at most two ceilings can
// leave in any 24 hours (a full bucket plus a day of refill). A meter belongs
// to a payouts epoch: when the epoch changes (a payouts flag was cleared) it
// empties first, as of the epoch's start (ADR pr6375 §7.1: meters start
// empty at launch, after a migration and whenever a payouts flag is cleared).
// Frac carries the refill's remainder in base units × seconds (below a day),
// so refills in any pieces sum to exactly rate a day.
//
// Ported from gnolang/bridges (ethereum-draft, a58efe81c9eb),
// solana/realm/p/hlroute/v0/hlroute.gno (Meter, refill), Copyright (C) 2026
// NewTendermint, LLC, GNO Network General Public License.
type Meter struct {
	Level uint256
	At    int64 // last refill, unix seconds
	Epoch int64 // the payouts epoch it last saw
	Frac  uint256
	// The rate and ceiling in effect since At, set by the last refill: the
	// time since At refills at them, never at a rate or ceiling given later
	// (a cap change, of the configuration or of the lock a cap derives from,
	// never rewrites the refill before it was seen).
	Rate, Ceil uint256
	Set        bool
}

// NewMeter is an empty meter as of now, in epoch.
func NewMeter(now, epoch int64) Meter {
	return Meter{At: now, Epoch: epoch}
}

// Refill brings the meter up to now and then sets rate and ceil for the
// time to come: the time since the last refill refills at the rate and up to
// the ceiling that refill set (the ones given now on a meter's first
// refill), so a new cap applies only from the refill that first sees it,
// never to the time before (ADR pr6375 §7.1, as Ethereum's buckets settle at
// the old cap); a configuration change refills its meters at the old cap,
// then at the new with no time elapsed (Route.Reconfigure), so the new one
// applies from the change. A new epoch empties the meter as of epochAt
// first. A ceiling below the level (the cap fell) brings the level down to
// it.
func (m *Meter) Refill(now int64, rate, ceil uint256, epoch, epochAt int64) {
	if m.Epoch != epoch {
		m.Level, m.At, m.Epoch, m.Frac = 0, epochAt, epoch, 0
	}
	newRate, newCeil := rate, ceil
	if m.Set {
		rate, ceil = m.Rate, m.Ceil
	}
	m.Rate, m.Ceil, m.Set = newRate, newCeil, true
	if now > m.At {
		el := now - m.At
		if el > Day {
			el = Day
			m.Frac = 0
		}
		e, day := uint256(el), uint256(Day)
		// (rate%Day)*el + Frac stays below 2·Day², so only the whole days'
		// part and the addition to the level can overflow: either fills the
		// meter, which saturates at the ceiling.
		num := (rate%day)*e + m.Frac
		whole, ok := overflow.Mulu256(rate/day, e)
		add, ok2 := overflow.Addu256(whole, num/day)
		m.Frac = num % day
		m.At = now
		if !ok || !ok2 || m.Level >= ceil || add >= ceil-m.Level {
			m.Level = ceil
		} else {
			m.Level += add
		}
	}
	if m.Level >= ceil {
		m.Level, m.Frac = ceil, 0
	}
	if m.Level >= newCeil {
		m.Level, m.Frac = newCeil, 0
	}
}

// Take removes amount from the level. The caller checked it is available.
func (m *Meter) Take(amount uint256) { m.Level = sub0(m.Level, amount) }
