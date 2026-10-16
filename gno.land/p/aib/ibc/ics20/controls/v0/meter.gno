package controls

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
	Level int64
	At    int64 // last refill, unix seconds
	Epoch int64 // the payouts epoch it last saw
	Frac  int64
}

// NewMeter is an empty meter as of now, in epoch.
func NewMeter(now, epoch int64) Meter {
	return Meter{At: now, Epoch: epoch}
}

// Refill brings the meter up to now at rate a day, never above ceil; a new
// epoch empties it as of epochAt first. A ceiling below the level (the cap
// fell) brings the level down to it. rate and ceil must be non-negative.
func (m *Meter) Refill(now, rate, ceil, epoch, epochAt int64) {
	if m.Epoch != epoch {
		m.Level, m.At, m.Epoch, m.Frac = 0, epochAt, epoch, 0
	}
	if rate < 0 {
		rate = 0
	}
	if ceil < 0 {
		ceil = 0
	}
	if now > m.At {
		el := now - m.At
		if el > Day {
			el = Day
			m.Frac = 0
		}
		num := (rate%Day)*el + m.Frac
		m.Level += (rate/Day)*el + num/Day
		m.Frac = num % Day
		m.At = now
	}
	if m.Level >= ceil {
		m.Level, m.Frac = ceil, 0
	}
}

// Take removes amount from the level. The caller checked it is available.
func (m *Meter) Take(amount int64) {
	m.Level -= amount
	if m.Level < 0 {
		m.Level = 0
	}
}
