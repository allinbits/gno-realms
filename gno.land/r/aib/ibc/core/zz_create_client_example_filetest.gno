package main

import (
	"crypto/sha256"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/r/aib/ibc/core"
)

func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	// CreateClient
	var (
		chainID      = "chain-id-2"  // XXX update
		latestHeight = types.Height{ // XXX update
			RevisionNumber: 2,
			RevisionHeight: 100,
		}
		clientState = tendermint.ClientState{
			ChainID:         chainID,
			TrustLevel:      tendermint.Fraction{2, 3},
			UnbondingPeriod: time.Hour * 3, // XXX update
			TrustingPeriod:  time.Hour,     // XXX update
			MaxClockDrift:   time.Hour,     // XXX update
			LatestHeight:    latestHeight,
			ProofSpecs:      ics23.GetSDKProofSpecs(),
		}
		apphash        = sha256.Sum256([]byte("apphash"))    // XXX update
		valhash        = sha256.Sum256([]byte("validators")) // XXX update
		timestamp      = time.Now()                          // XXX update
		consensusState = tendermint.ConsensusState{
			Timestamp:          timestamp,
			Root:               tendermint.MerkleRoot{Hash: apphash[:]},
			NextValidatorsHash: valhash[:],
		}
	)
	id := core.CreateClient(cross, clientState, consensusState)
	println(id)
}

// Output:
// 07-tendermint-1
