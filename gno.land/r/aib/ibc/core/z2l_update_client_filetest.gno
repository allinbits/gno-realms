package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient validatorhash and nextValidatorHash mismatch
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
	// Alter valset
	valset.Validators[0].VotingPower++
	msgHeader := tmtesting.GenMsgHeader(
		chainID, newTimestamp, apphash, newHeight, trustedHeight, valset, nextValset, trustedValset,
	)

	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// expected old header next validators (ffd80d3732ba201715593c01b2c913aeb2a4fd2433776f61d703fc2d81496caa) to match those from new header (6091db5499156b9e20fce74692a505af4ec365378e16f58777947f852ccc5aa1)
