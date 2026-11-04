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

// UpgradeClient failure: caller not in relayer whitelist
func main(cur realm) {
	// Bootstrap: the test caller is admin, but we add a DIFFERENT address
	// as the only authorized relayer. Subsequent core entrypoints called
	// from the test caller fail the relayer gate.
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.AddRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	var (
		clientState    = tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)

	// Replace the whitelist entry with a different address so the test
	// caller is no longer authorized.
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.RemoveRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross(cur), "g100000000000000000000000000000000000000")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	core.UpgradeClient(cross(cur), clientID, nil, nil, nil, nil)
}

// Error:
// unauthorized relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
