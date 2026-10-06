// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
)

// RecoverClient failure: subject client is Active (not Frozen or Expired).
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
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
// cannot recover subject client 07-tendermint-1 with status Active
