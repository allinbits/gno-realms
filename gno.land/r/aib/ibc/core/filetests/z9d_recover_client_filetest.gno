// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// RecoverClient failure: subject client is Active (not Frozen or Expired).
func main(cur realm) {
	var (
		clientState    = tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), trustedValset.Hash())
	)
	subjectID := core.CreateClient(cross(cur), clientState, consensusState)
	substituteID := core.CreateClient(cross(cur), clientState, consensusState)

	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.RecoverClient(cross(cur), subjectID, substituteID)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// Error:
// cannot recover subject client 07-tendermint-1 with status Active
