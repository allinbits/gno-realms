package main

import (
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// CreateClient with non-empty whitelist (only whitelisted relayers allowed)
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1someother00000000000000000000000000")
	// Note: caller is not in the whitelist

	var (
		chainID        = "chain-id-1"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(1, 2))
		apphash        = tmtesting.Hash("apphash")
		val1           = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
			"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)
		val2           = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
			"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 1)
		trustedValset  = tendermint.NewValset(val1, val2)
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	core.CreateClient(cross, clientState, consensusState)
}

// Error:
// unauthorized relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm