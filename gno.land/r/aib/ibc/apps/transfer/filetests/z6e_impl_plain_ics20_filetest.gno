// PKGPATH: gno.land/r/aib/ibc/apps/transfer/impl/plain
package plain

import (
	"chain"
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"

	"gno.land/r/aib/ibc/apps/transfer"
	ics20impl "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const self = "gno.land/r/aib/ibc/apps/transfer/impl/plain"

// The plain ICS-20 app runs alone: a wrapper realm, as a chain without
// Ethereum would deploy (or the upgrade rehearsal), registers ics20.New
// without the route controls, governance activates it (no route exists), and
// a transfer over a Tendermint client escrows as under the installed
// controls (z5a).
func init(cur realm) {
	transfer.RegisterImpl(cross(cur), ics20impl.New, "v0", nil, false)
}

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), ibcgov.NewTransferUpdateImplRequest(cross(cur), self))
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(7*24*time.Hour + time.Second)
	testing.SetContext(ctx)
	ibcgov.Execute(cross(cur), ibcgov.LastDecision())
	testing.SetRealm(testing.NewCodeRealm(self))
	println("active:", transfer.ImplPath(), transfer.ImplVersion())
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	testing.SetRealm(testing.NewUserRealm("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 100)))
	transfer.Transfer(cross(cur), clientID, "atone1user", "ugnot", 100, uint64(time.Now().Add(time.Hour).Unix()), "memo")
	println(transfer.Render("total_escrow/ugnot"))
}

// Output:
// active: gno.land/r/aib/ibc/apps/transfer/impl/plain v0
// {"denom":"ugnot","amount":100,"clients":[{"client":"07-tendermint-1","amount":100}]}
