package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient revision number mismatch
func main() {
	// CreateClient and RegisterCounterparty
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		valset         = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, valset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Update clientID
	var (
		newHeight     = clientState.LatestHeight.RevisionHeight + 1
		newTimestamp  = consensusState.Timestamp.Add(time.Minute)
		trustedHeight = clientState.LatestHeight
	)
	// Alter chainID to change the revision number
	chainID = "chain-id-3"
	msgHeader := tmtesting.GenMsgHeader(
		chainID, newTimestamp, apphash, newHeight, trustedHeight, valset, valset, valset,
	)

	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// header height revision 3 does not match trusted header revision 2
