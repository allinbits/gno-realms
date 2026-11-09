// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/lightclient/tendermint/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Assert calls to clientState.ValidateBasic and consensusState.ValidateBasic,
// each with a real Tendermint state that fails it.
// NOTE: We don't want to test ValidateBasic() checks in filetest because it
// has too many cases, hence ValidateBasic is tested in unittests and we only
// ensure that the ValidateBasic() method are properly invoked.
func main(cur realm) {
	var (
		chainID        = "chain-id-2"
		clientState    = testing.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = testing.GenValset()
		consensusState = testing.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	noChainID := clientState
	noChainID.ChainID = ""
	noRoot := consensusState
	noRoot.Root = tendermint.MerkleRoot{}

	println("clientState.ValidateBasic:",
		// NOTE: panics in explicit cross realm can only be caught by revive.
		revive(func() {
			core.CreateClient(cross(cur), noChainID, consensusState)
		}))
	println("consensusState.ValidateBasic:",
		revive(func() {
			core.CreateClient(cross(cur), clientState, noRoot)
		}))
}

// Output:
// clientState.ValidateBasic: chainID cannot be empty string
// consensusState.ValidateBasic: root cannot be empty
