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

// RegisterCounterparty with a counterparty client id longer than 64 characters (the ICS-024 limit, enforced by ibc-go): it is stored
// and rendered with the client, so its size is bounded.
func main(cur realm) {
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash())
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("ibc"), []byte("")}, strings.Repeat("a", 54) + "-tendermint-1")
}

// Error:
// invalid counterparty client id
