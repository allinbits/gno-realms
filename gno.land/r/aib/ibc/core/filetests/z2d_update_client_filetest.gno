// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// UpdateClient client type mismatch: a valid Tendermint header for an
// Ethereum client, both our own types.
func main(cur realm) {
	clientID := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{}}, "client-0")

	valset := tmtesting.GenValset()
	header := tmtesting.GenMsgHeader("chain-id-2", time.Now(), tmtesting.Hash("apphash"), 3, types.NewHeight(2, 2), valset, valset, valset)
	core.UpdateClient(cross(cur), clientID, header)
}

// Error:
// client type for client state and client message do not match
