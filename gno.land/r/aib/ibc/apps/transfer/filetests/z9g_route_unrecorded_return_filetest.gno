// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"chain/banker"
	"strconv"
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

var (
	collector = testutils.TestAddress("collector")
	sender    = testutils.TestAddress("sender")
	bob       = testutils.TestAddress("bob")
)

const (
	ethReceiver = "0x5f67a5398d91087d1b37a8a43436196a7830867f"
	weth        = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"
)

// advance moves the block time on by d.
func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

// govern makes a decision as the governor and returns its number.
func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

// execute applies a queued decision once its 7 days have passed.
func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

// setupRoute creates an Ethereum client, installs transfer impl/v1 and
// enrolls the client as a route, every step a governor decision.
func setupRoute(cur realm) string {
	clientID := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1")))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector))))
	return clientID
}

// send transfers amount of ugnot from sender to an Ethereum receiver, sending
// coins with the call (the coins land at the transfer realm first).
func send(cur realm, route string, amount, coins int64, receiver string) uint64 {
	testing.IssueCoins(chain.PackageAddress(transfer.PkgPath), chain.NewCoins(chain.NewCoin("ugnot", coins)))
	testing.SetRealm(testing.NewUserRealm(sender))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", coins)))
	_, seq := transfer.Transfer(cross(cur), route, receiver, "ugnot", amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

// recv delivers a packet from Ethereum to the transfer app as the core does
// after verifying its proof.
func recv(cur realm, route string, seq uint64, denom, receiver string, amount int64) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatInt(amount, 10), "0x5f67a5398d91087d1b37a8a43436196a7830867f", receiver, "")
	bz, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), "client-0", route, seq, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return res
}

func controlsView() controls.Reader { return transfer.ExtView("controls").(controls.Reader) }

func ugnot(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, "ugnot") }

// A voucher minted by impl/v0 before the Ethereum client became a route goes
// back to Ethereum under impl/v1 even though the route does not account its
// denom: a return is never refused. It has no send record, so its timeout
// refunds it at once, minted back under the voucher's denom.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	println("impl:", transfer.ImplVersion(), "| receive:", recv(cur, client, 1, weth, bob.String(), 100).Status)
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", client)).IBCDenom()
	println("bob's vouchers under v0:", transfer.VoucherBalanceOf(voucher, bob))

	execute(cur, govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1")))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(collector))))
	println("impl:", transfer.ImplVersion(), "| denoms on the route:", len(controlsView().Denoms(client)))

	testing.SetRealm(testing.NewUserRealm(bob))
	packet, seq := transfer.Transfer(cross(cur), client, ethReceiver, voucher, 40, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	_, recorded := controlsView().Send(client, controls.PacketKey(client, seq))
	println("returned 40:", seq, "recorded:", recorded, "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	if err := app.OnTimeoutPacket(cross(cur), client, "client-0", seq, packet.Payloads[0]); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("after the timeout, bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))
}

// Output:
// impl: v0 | receive: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// bob's vouchers under v0: 100
// impl: v1 | denoms on the route: 0
// returned 40: 1 recorded: false | bob's vouchers: 60
// after the timeout, bob's vouchers: 100
