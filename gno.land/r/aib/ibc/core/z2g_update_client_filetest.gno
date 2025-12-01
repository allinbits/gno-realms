package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient consensusState.NextValidatorHash and nextValset mismatch
func main() {
	// CreateClient and RegisterCounterparty
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Update clientID
	var (
		newHeight     = clientState.LatestHeight.RevisionHeight + 1
		newTimestamp  = consensusState.Timestamp.Add(time.Minute)
		trustedHeight = clientState.LatestHeight
		valset        = tmtesting.GenValset()
		nextValset    = tmtesting.GenValset()
	)
	// Alter trustedValset
	trustedValset.Validators[0].VotingPower = 42
	msgHeader := tmtesting.GenMsgHeader(
		chainID, newTimestamp, apphash, newHeight, trustedHeight, valset,
		nextValset, trustedValset,
	)

	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// trusted validators do not hash to latest trusted validators. Expected: "ffd80d3732ba201715593c01b2c913aeb2a4fd2433776f61d703fc2d81496caa", got: "9232cad0b329a571879d270410b02ff96635f8b71f77544cb768a5fcf56f0719"
