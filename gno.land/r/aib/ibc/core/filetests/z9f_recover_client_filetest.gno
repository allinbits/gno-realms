// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// RecoverClient failure: caller is not the admin.
func main(cur realm) {
	// Admin is set to a different address than the test caller.
	core.SetAdmin(cross(cur), "g1somebodyelse00000000000000000000000000")
	var (
		clientState    = tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), trustedValset.Hash())
	)
	subjectID := core.CreateClient(cross(cur), clientState, consensusState)
	substituteID := core.CreateClient(cross(cur), clientState, consensusState)

	core.RecoverClient(cross(cur), subjectID, substituteID)
}

// Error:
// unauthorized: caller g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm is not the admin
