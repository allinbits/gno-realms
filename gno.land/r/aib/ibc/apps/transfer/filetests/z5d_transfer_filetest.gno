// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/testing/grc20test"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// TransferGRC20: no approval (insufficient allowance)
func main(cur realm) {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Mint tokens but do NOT approve the transfer app
	grc20test.Mint(cross(cur), cur.Previous().Address(), 1000)

	denom := "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug
	transfer.Transfer(cross(cur), clientID, "atone1user", denom, 100, uint64(time.Now().Add(time.Hour).Unix()), "")
}

// Error:
// send packet failed for payload #0 app "transfer": escrow GRC20 gno.land/r/aib/ibc/apps/testing/grc20test.TEST error: insufficient allowance
