// PKGPATH: gno.land/r/aib/main
package main

// Regression test: a non-IBC GRC20 Transfer initiated by a non-user caller
// must be rejected even when the user has granted the transfer app allowance.

import (
	"chain"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/testing/grc20test"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

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

	owner := cur.Previous().Address()

	grc20test.Mint(cross(cur), owner, 1000)
	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	grc20test.Approve(cross(cur), owner, transferAppAddr, 100)

	denom := "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug
	transfer.Transfer(cross(cur), clientID, "atone1user", denom, 100, uint64(time.Now().Add(time.Hour).Unix()), "")
}

// Error:
// GRC20 transfer must be a direct user call (maketx call)
