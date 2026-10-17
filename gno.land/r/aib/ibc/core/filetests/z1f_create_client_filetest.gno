// PKGPATH: gno.land/r/aib/main
package main

import (
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// CreateClient w/ client type mismatch: a Tendermint client state with an
// Ethereum consensus state, both our own types.
func main(cur realm) {
	core.CreateClient(cross(cur), testing.NewClientState("chainid", types.NewHeight(2, 2)), ethtesting.ConsensusState())
}

// Error:
// client type for client state and consensus state do not match
