package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// CreateClient unauthorized relayer
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	// caller is admin but not in the relayer whitelist

	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	core.CreateClient(cross, clientState, consensusState)
}

// Error:
// unauthorized relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
