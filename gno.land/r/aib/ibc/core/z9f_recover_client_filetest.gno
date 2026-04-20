package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// RecoverClient failure: caller is not the admin.
func main() {
	// Admin is set to a different address than the test caller.
	core.SetAdmin(cross, "g1somebodyelse00000000000000000000000000")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	var (
		clientState    = tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), trustedValset.Hash())
	)
	subjectID := core.CreateClient(cross, clientState, consensusState)
	substituteID := core.CreateClient(cross, clientState, consensusState)

	core.RecoverClient(cross, subjectID, substituteID)
}

// Error:
// unauthorized: caller g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm is not the admin
