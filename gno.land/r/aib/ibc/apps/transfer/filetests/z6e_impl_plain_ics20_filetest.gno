// PKGPATH: gno.land/r/aib/ibc/apps/transfer/impl/plain
package plain

import (
	"chain"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/v0"
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
// controls (z5a). A router client (Ethereum's) is the route controls'
// alone: the plain app refuses a send to one before anything moves (a
// packet it escrowed there would have no send record for controls installed
// later to settle its refund against) and fails a receive over one, which
// its source then refunds.
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
	// A native amount above the chain's coin maximum is refused as such, as
	// the controls refuse it (review of #85).
	println("above the coin maximum:", revive(func() {
		transfer.Transfer(cross(cur), clientID, "atone1user", "ugnot", 1<<63, uint64(time.Now().Add(time.Hour).Unix()), "")
	}))

	testing.SetRealm(testing.NewCodeRealm(self))
	eth := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), eth, [][]byte{{}}, "client-0")
	testing.SetRealm(testing.NewUserRealm("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 5)))
	println("send to", eth, "(router:", core.IsRouterClient(eth), "):", revive(func() {
		transfer.Transfer(cross(cur), eth, "0x00000000000000000000000000000000000000aa", "ugnot", 5, uint64(time.Now().Add(time.Hour).Unix()), "")
	}))
	println(transfer.Render("total_escrow/ugnot"))

	data := ics20.NewFungibleTokenPacketData("0xabc", "7", "0x5f67a5398d91087d1b37a8a43436196a7830867f", "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm", "")
	bz, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), "client-0", eth, 1, payload)
	println("receive over", eth, "failed:", res.Status == types.PacketStatus_Failure)
}

// Output:
// active: gno.land/r/aib/ibc/apps/transfer/impl/plain v0
// {"denom":"ugnot","amount":"100","clients":[{"client":"07-tendermint-1","amount":"100"}]}
// above the coin maximum: 9223372036854775808 ugnot is above the chain's coin maximum
// send to ethereum-2 (router: true ): ethereum-2 is a router client: its transfers need the route controls (impl/controls), not the plain ICS-20 app
// {"denom":"ugnot","amount":"100","clients":[{"client":"07-tendermint-1","amount":"100"}]}
// receive over ethereum-2 failed: true
