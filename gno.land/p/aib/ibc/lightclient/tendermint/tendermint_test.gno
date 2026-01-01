package tendermint_test

import (
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/urequire"
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
