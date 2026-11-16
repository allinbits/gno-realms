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

// RegisterCounterparty with a counterparty merkle prefix key longer than 64 bytes: it is stored
// and rendered with the client, so its size is bounded.
func main(cur realm) {
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash())
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("ibc"), []byte(strings.Repeat("p", 65))}, "07-tendermint-42")
}

// Error:
// counterparty merkle prefix key 1 is 65 bytes, max 64
