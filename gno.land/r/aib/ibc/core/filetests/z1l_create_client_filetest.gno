// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// CreateClient with proof specs that differ from the Cosmos SDK ones only in
// InnerSpec.EmptyChild, which SpecEquals ignores: set to an inner node's
// suffix, it made a non-existence proof verify for a key in the tree.
func main(cur realm) {
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	clientState.ProofSpecs[0].InnerSpec.EmptyChild = append([]byte{32}, tmtesting.Hash("sibling")...)
	consensusState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash())
	core.CreateClient(cross(cur), clientState, consensusState)
}

// Error:
// proof specs must be the Cosmos SDK IAVL and Tendermint specs (ics23.GetSDKProofSpecs)
