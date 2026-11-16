// PKGPATH: gno.land/r/demo/attacker
package attacker

import (
	"strings"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// prefix is this realm's own, persistent: what it hands the core.
var prefix = [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}

// Every route, this Tendermint one included (ADR 0004, "Changes affecting
// every route"): the core keeps its own copy of a counterparty's merkle
// prefix. In the base (1e0c7c5) it kept the caller's slice, so the creator's
// later change to it moved the path every proof of the client is checked
// under.
func main(cur realm) {
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), []byte("apphash"), tmtesting.GenValset().Hash())
	id := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), id, prefix, "07-tendermint-42")
	before := core.Render("clients/" + id)
	prefix[1] = []byte("elsewhere")
	after := core.Render("clients/" + id)
	i := strings.Index(after, `"counterparty_merke_prefix"`)
	println("prefix unchanged:", before == after, "|", after[i:i+60])
}

// Output:
// prefix unchanged: true | "counterparty_merke_prefix":["iavlStoreKey","prefix2"],"clie
