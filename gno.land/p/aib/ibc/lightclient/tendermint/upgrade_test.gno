package tendermint

import (
	"testing"
	"time"

	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestCalculateNewTrustingPeriod(t *testing.T) {
	hour := time.Hour
	day := 24 * time.Hour
	week := 7 * day

	t.Run("scales proportionally when unbonding shrinks", func(t *testing.T) {
		// trusting=2 weeks, current unbonding=3 weeks, new unbonding=2 weeks
		// → new trusting = 2w * 2w / 3w = ~9.33d, truncated to seconds.
		got := calculateNewTrustingPeriod(2*week, 3*week, 2*week)
		want := time.Duration((2 * week / time.Second) * (2 * week / time.Second) / (3 * week / time.Second)) * time.Second
		uassert.Equal(t, int64(want), int64(got))
		// Sanity: result is strictly less than original trusting period.
		uassert.True(t, got < 2*week)
	})

	t.Run("equal unbonding leaves trusting unchanged (modulo second truncation)", func(t *testing.T) {
		got := calculateNewTrustingPeriod(2*week, 3*week, 3*week)
		uassert.Equal(t, int64(2*week), int64(got))
	})

	t.Run("zero current unbonding returns zero rather than panicking", func(t *testing.T) {
		got := calculateNewTrustingPeriod(hour, 0, hour)
		uassert.Equal(t, int64(0), int64(got))
	})

	t.Run("sub-second trusting truncates to zero", func(t *testing.T) {
		// Documented loss of precision: math is performed in seconds.
		got := calculateNewTrustingPeriod(500*time.Millisecond, week, week)
		uassert.Equal(t, int64(0), int64(got))
	})
}

func TestBuildUpgradeMerklePath(t *testing.T) {
	height := types.NewHeight(1, 100)

	t.Run("canonical two-element path keeps elements separate", func(t *testing.T) {
		mp := buildUpgradeMerklePath([]string{"upgrade", "upgradedIBCState"}, "upgradedClient", height)
		urequire.Equal(t, 2, len(mp.KeyPath))
		uassert.Equal(t, "upgrade", string(mp.KeyPath[0]))
		uassert.Equal(t, "upgradedIBCState/100/upgradedClient", string(mp.KeyPath[1]))
	})

	t.Run("single-element path produces a single key with the suffix", func(t *testing.T) {
		mp := buildUpgradeMerklePath([]string{"upgrade"}, "upgradedConsState", height)
		urequire.Equal(t, 1, len(mp.KeyPath))
		uassert.Equal(t, "upgrade/100/upgradedConsState", string(mp.KeyPath[0]))
	})

	t.Run("three-element path keeps each prefix segment separate", func(t *testing.T) {
		mp := buildUpgradeMerklePath([]string{"a", "b", "c"}, "upgradedClient", height)
		urequire.Equal(t, 3, len(mp.KeyPath))
		uassert.Equal(t, "a", string(mp.KeyPath[0]))
		uassert.Equal(t, "b", string(mp.KeyPath[1]))
		uassert.Equal(t, "c/100/upgradedClient", string(mp.KeyPath[2]))
	})
}
