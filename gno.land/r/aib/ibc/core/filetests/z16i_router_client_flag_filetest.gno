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

// Whether a client's counterparty is an ICS26 router is recorded when the
// implementation creates it (core.IsRouterClient), not read off its type by
// every application: an Ethereum client is one, a Tendermint client is not,
// and an unknown client is none.
func main(cur realm) {
	eth := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	tm := core.CreateClient(cross(cur),
		tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2)),
		tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash()))
	println(eth, "router:", core.IsRouterClient(eth))
	println(tm, "router:", core.IsRouterClient(tm))
	println("unknown router:", core.IsRouterClient("ethereum-99"))
}

// Output:
// ethereum-1 router: true
// 07-tendermint-2 router: false
// unknown router: false
