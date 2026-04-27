package main

// PKGPATH: gno.land/r/aib/main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpgradeClient failure: caller not in relayer whitelist
func main() {
	// Bootstrap: the test caller is admin, but we add a DIFFERENT address
	// as the only authorized relayer. Subsequent core entrypoints called
	// from the test caller fail the relayer gate.
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")

	var (
		clientState    = tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)

	// Replace the whitelist entry with a different address so the test
	// caller is no longer authorized.
	core.RemoveRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g100000000000000000000000000000000000000")

	core.UpgradeClient(cross, clientID, nil, nil, nil, nil)
}

// Error:
// unauthorized relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
