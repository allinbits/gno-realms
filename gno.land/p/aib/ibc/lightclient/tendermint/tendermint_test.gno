package tendermint_test

import (
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestGetNeighboringConsensusStates(t *testing.T) {
	tm := tendermint.NewTMLightClient()
	nextValsHash := []byte("nextVals")
	height01 := types.NewHeight(0, 1)
	cs01 := &tendermint.ConsensusState{
		Timestamp:          time.Now().UTC(),
		Root:               tendermint.NewMerkleRoot([]byte("hash0-1")),
		NextValidatorsHash: nextValsHash,
	}
	clientState := tendermint.NewClientState(chainID, tendermint.DefaultTrustLevel, trustingPeriod, ubdPeriod, maxClockDrift, height01, ics23.GetSDKProofSpecs(), upgradePath)
	err := tm.Initialize(*clientState, *cs01)
	urequire.NoError(t, err)

	cs04 := &tendermint.ConsensusState{
		Timestamp:          time.Now().UTC(),
		Root:               tendermint.NewMerkleRoot([]byte("hash0-4")),
		NextValidatorsHash: nextValsHash,
	}
	cs49 := &tendermint.ConsensusState{
		Timestamp:          time.Now().UTC(),
		Root:               tendermint.NewMerkleRoot([]byte("hash4-9")),
		NextValidatorsHash: nextValsHash,
	}
	height04 := types.NewHeight(0, 4)
	height49 := types.NewHeight(4, 9)
	tm.SetConsensusState(height04, cs04)
	tm.SetConsensusState(height49, cs49)

	// Previous height01 should return nil
	prevCs01, ok := tm.GetPreviousConsensusState(height01)
	urequire.True(t, prevCs01 == nil, "consensus state exists before lowest consensus state")
	urequire.False(t, ok)

	// Previous from non existing height02 should return cs01
	prevCs02, ok := tm.GetPreviousConsensusState(types.NewHeight(0, 2))
	urequire.Equal(t, string(cs01.Root.Hash), string(prevCs02.Root.Hash),
		"previous consensus state is not returned correctly")
	urequire.True(t, ok)

	// Previous from height49 should return cs04
	prevCs49, ok := tm.GetPreviousConsensusState(height49)
	urequire.Equal(t, string(cs04.Root.Hash), string(prevCs49.Root.Hash),
		"previous consensus state is not returned correctly")
	urequire.True(t, ok)

	// Next from height01 should return cs04
	nextCs01, ok := tm.GetNextConsensusState(height01)
	urequire.Equal(t, string(cs04.Root.Hash), string(nextCs01.Root.Hash),
		"next consensus state not returned correctly")
	urequire.True(t, ok)

	// Next from non existing height02 should return cs04
	nextCs02, ok := tm.GetNextConsensusState(types.NewHeight(0, 2))
	urequire.Equal(t, string(cs04.Root.Hash), string(nextCs02.Root.Hash),
		"next consensus state not returned correctly")
	urequire.True(t, ok)

	// Next from height49 should return nil
	nextCs49, ok := tm.GetNextConsensusState(height49)
	urequire.True(t, nextCs49 == nil, "next consensus state exists after highest consensus state")
	urequire.False(t, ok)
}

func TestRecoverClient(t *testing.T) {
	newConsState := func(root string) *tendermint.ConsensusState {
		return &tendermint.ConsensusState{
			Timestamp:          time.Now().UTC(),
			Root:               tendermint.NewMerkleRoot([]byte(root)),
			NextValidatorsHash: []byte("nextVals"),
		}
	}
	// Build two clients with matching immutable parameters, different chainIDs
	// and different latest heights.
	newSubject := func() *tendermint.TMLightClient {
		tm := tendermint.NewTMLightClient()
		cs := tendermint.NewClientState("subject-chain", tendermint.DefaultTrustLevel,
			trustingPeriod, ubdPeriod, maxClockDrift, types.NewHeight(0, 5),
			ics23.GetSDKProofSpecs(), upgradePath)
		urequire.NoError(t, tm.Initialize(*cs, *newConsState("subject-root")))
		// Freeze the subject so its status becomes Frozen (for realism; not
		// required by RecoverClient itself).
		tm.ClientState.FrozenHeight = tendermint.FrozenHeight
		return tm
	}
	newSubstitute := func() *tendermint.TMLightClient {
		tm := tendermint.NewTMLightClient()
		cs := tendermint.NewClientState("substitute-chain", tendermint.DefaultTrustLevel,
			trustingPeriod, ubdPeriod, maxClockDrift, types.NewHeight(0, 10),
			ics23.GetSDKProofSpecs(), upgradePath)
		urequire.NoError(t, tm.Initialize(*cs, *newConsState("substitute-root")))
		return tm
	}

	t.Run("success", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()

		err := subject.RecoverClient(substitute)
		urequire.NoError(t, err)

		uassert.Equal(t, "substitute-chain", subject.ClientState.ChainID)
		uassert.True(t, subject.ClientState.LatestHeight.EQ(types.NewHeight(0, 10)))
		uassert.True(t, subject.ClientState.FrozenHeight.IsZero())
		// Substitute consensus state at height (0,10) must have been copied.
		cs, found := subject.GetConsensusState(types.NewHeight(0, 10))
		urequire.True(t, found, "consensus state at substitute latest height not copied")
		uassert.Equal(t, "substitute-root", string(cs.Root.Hash))
	})

	t.Run("failure: substitute not a *TMLightClient", func(t *testing.T) {
		subject := newSubject()

		err := subject.RecoverClient(nil)
		urequire.Error(t, err)
		urequire.ErrorContains(t, err, "substitute client type mismatch")
	})

	t.Run("success: substitute TrustingPeriod is adopted", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()
		substitute.ClientState.TrustingPeriod = trustingPeriod + time.Hour

		err := subject.RecoverClient(substitute)
		urequire.NoError(t, err)
		uassert.Equal(t, int64(trustingPeriod+time.Hour), int64(subject.ClientState.TrustingPeriod))
	})

	t.Run("failure: mismatching max clock drift", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()
		substitute.ClientState.MaxClockDrift = maxClockDrift + time.Second

		err := subject.RecoverClient(substitute)
		urequire.Error(t, err)
		urequire.ErrorContains(t, err, "differ on MaxClockDrift")
	})

	t.Run("failure: mismatching trust level", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()
		substitute.ClientState.TrustLevel = tendermint.NewFraction(2, 3)

		err := subject.RecoverClient(substitute)
		urequire.Error(t, err)
		urequire.ErrorContains(t, err, "differ on TrustLevel")
	})

	t.Run("failure: mismatching unbonding period", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()
		substitute.ClientState.UnbondingPeriod = ubdPeriod + time.Hour

		err := subject.RecoverClient(substitute)
		urequire.Error(t, err)
		urequire.ErrorContains(t, err, "differ on UnbondingPeriod")
	})

	t.Run("failure: mismatching proof specs", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()
		substitute.ClientState.ProofSpecs = substitute.ClientState.ProofSpecs[:1]

		err := subject.RecoverClient(substitute)
		urequire.Error(t, err)
		urequire.ErrorContains(t, err, "differ on ProofSpecs")
	})

	t.Run("failure: mismatching upgrade path", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()
		substitute.ClientState.UpgradePath = []string{"otherUpgrade"}

		err := subject.RecoverClient(substitute)
		urequire.Error(t, err)
		urequire.ErrorContains(t, err, "differ on UpgradePath")
	})

	t.Run("failure: missing consensus state at substitute latest height", func(t *testing.T) {
		subject := newSubject()
		substitute := newSubstitute()
		// Drop the consensus state that Initialize stored.
		substitute.ConsensusStateByHeight.Remove(substitute.ClientState.LatestHeight.StringNatSort())

		err := subject.RecoverClient(substitute)
		urequire.Error(t, err)
		urequire.ErrorContains(t, err, "substitute consensus state not found")
	})

	// Assertion that interface conformance holds when calling through the
	// lightclient.Interface type (catches future signature drift).
	t.Run("success via Interface", func(t *testing.T) {
		subject := newSubject()
		var substitute lightclient.Interface = newSubstitute()

		err := subject.RecoverClient(substitute)
		urequire.NoError(t, err)
	})
}
