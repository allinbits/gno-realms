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

// RecoverClient failure: substitute client not found.
func main(cur realm) {
	var (
		clientState    = tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), trustedValset.Hash())
	)
	subjectID := core.CreateClient(cross(cur), clientState, consensusState)

	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.RecoverClient(cross(cur), subjectID, "07-tendermint-99")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// Error:
// substitute client 07-tendermint-99 not found
