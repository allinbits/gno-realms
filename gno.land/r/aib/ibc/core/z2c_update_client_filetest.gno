package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient trustedHeight not found
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
		newHeight     = clientState.LatestHeight.RevisionHeight + 3
		newTimestamp  = consensusState.Timestamp.Add(time.Minute)
		trustedHeight = types.NewHeight(2, 3)
		msgHeader     = tmtesting.GenMsgHeader(
			chainID, newTimestamp, apphash, newHeight, trustedHeight, valset, valset, valset,
		)
	)

	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// could not get trusted consensus state for Header at TrustedHeight: 2/3
