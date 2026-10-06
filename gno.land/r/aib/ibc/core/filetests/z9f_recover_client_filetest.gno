// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// RecoverClient failure: caller is not the admin.
func main(cur realm) {
	// Admin is set to a different address than the test caller.
	core.AddAuthorityMember(cross(cur), "g1somebodyelse00000000000000000000000000")
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
// recover_client: caller g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9 is not a member of the authority
