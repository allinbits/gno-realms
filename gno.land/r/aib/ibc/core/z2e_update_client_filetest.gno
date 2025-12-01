package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient on expired lightclient
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

	// Change block time to expire the lightclient
	ctx := testing.GetContext()
	ctx.Time = time.Now().Add(clientState.TrustingPeriod)
	testing.SetContext(ctx)

	// Update clientID
	var (
		newHeight     = clientState.LatestHeight.RevisionHeight + 1
		newTimestamp  = consensusState.Timestamp.Add(time.Minute)
		trustedHeight = clientState.LatestHeight
		msgHeader     = tmtesting.GenMsgHeader(
			chainID, newTimestamp, apphash, newHeight, trustedHeight, valset, valset, valset,
		)
	)

	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// cannot update client (07-tendermint-1) with status Expired
