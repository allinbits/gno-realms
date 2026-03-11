// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	// Import to trigger the init and register the app
	"gno.land/r/aib/ibc/apps/vaas/consumer"
	_ "gno.land/r/aib/ibc/apps/vaas/consumer"
	"gno.land/r/aib/ibc/core"
)

// init: ensure app is registered
func main() {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	println("----------- assert render apps")
	println(core.Render("apps"))

	println("\n----------- assert realm config")
	println(consumer.Render("config"))
}

// Output:
// ----------- assert render apps
// [{"port_id":"consumer","pkg_path":"gno.land/r/aib/ibc/apps/vaas/consumer","address":"g1x4tk6nkmvvh9vqer7kudvaz0jywt6ur63qjds5"}]
//
// ----------- assert realm config
// {"port_id":"consumer","provider_port_id":"provider","version":"1","encoding":"application/json"}
