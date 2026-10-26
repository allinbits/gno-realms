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

// Render home with more clients than it lists: clients are never removed and,
// while the relayer whitelist is empty, anyone may create one, so the home
// page lists the first 100 and keeps the count exact.
func main(cur realm) {
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash())
	for i := 0; i < 101; i++ {
		core.CreateClient(cross(cur), clientState, consensusState)
	}

	rows := 0
	for _, line := range strings.Split(core.Render(""), "\n") {
		switch {
		case strings.HasPrefix(line, "## Clients"), strings.HasPrefix(line, "First "):
			println(line)
		case strings.HasPrefix(line, "| [`07-tendermint-"):
			rows++
		}
	}
	println("client rows:", rows)
}

// Output:
// ## Clients (101)
// First 100 of 101 clients; see [`clients`](/r/aib/ibc/core:clients) (`?page`, `?limit`) for all of them.
// client rows: 100
