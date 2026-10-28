// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Render the clients route asking for 100 clients per page: a client's
// document costs about 31M gas to render, so a page holds at most 20 of them
// to stay within the gas a query may use.
func main(cur realm) {
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash())
	for i := 0; i < 21; i++ {
		core.CreateClient(cross(cur), clientState, consensusState)
	}
	for _, page := range []string{"1", "2"} {
		out := core.Render("clients?limit=100&page=" + page)
		println("page", page, "clients:", strings.Count(out, `"id":"07-tendermint-`), out[strings.LastIndex(out, `"page"`):])
	}
}

// Output:
// page 1 clients: 20 "page":1,"total":2}
// page 2 clients: 1 "page":2,"total":2}
