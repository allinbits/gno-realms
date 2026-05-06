package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// RecoverClient failure: subject client not found.
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	var (
		clientState    = tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), trustedValset.Hash())
	)
	substituteID := core.CreateClient(cross, clientState, consensusState)

	core.RecoverClient(cross, "07-tendermint-99", substituteID)
}

// Error:
// subject client 07-tendermint-99 not found
