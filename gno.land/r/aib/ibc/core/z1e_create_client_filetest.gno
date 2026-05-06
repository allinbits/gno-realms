package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// CreateClient with Status Expired
func main() {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	// consensusState.Timestamp is older than now + clientState.TrustingPeriod
	consensusState.Timestamp = time.Now().Add(-clientState.TrustingPeriod)

	core.CreateClient(cross, clientState, consensusState)
}

// Error:
// cannot create client (07-tendermint-1) with status Expired
