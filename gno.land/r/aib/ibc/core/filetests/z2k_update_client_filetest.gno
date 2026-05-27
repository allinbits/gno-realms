// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient height older than trusted height
func main(cur realm) {
	// CreateClient and RegisterCounterparty
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Update clientID with height older than trusted height
	var (
		newHeight     = clientState.LatestHeight.RevisionHeight - 1
		newTimestamp  = consensusState.Timestamp.Add(time.Minute)
		trustedHeight = clientState.LatestHeight
		msgHeader     = tmtesting.GenMsgHeader(
			chainID, newTimestamp, apphash, newHeight, trustedHeight, trustedValset, trustedValset, trustedValset,
		)
	)

	core.UpdateClient(cross(cur), clientID, msgHeader)
}

// Error:
// trustedHeight 2/2 must be less than header height 2/1
