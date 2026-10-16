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

// recvOn delivers a packet arriving on client dst from the router client src.
func recvOn(cur realm, src, dst string, seq uint64, denom, receiver string, amount int64) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatInt(amount, 10), ethReceiver, receiver, "")
	bz, _ := abi.Marshal(data)
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), src, dst, seq, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return res
}

func sendVoucher(cur realm, client, voucher string, amount int64) uint64 {
	testing.SetRealm(testing.NewUserRealm(bob))
	_, seq := transfer.Transfer(cross(cur), client, ethReceiver, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

func wireDenom(route, client string, seq uint64) string {
	rec, _ := controlsView().Send(route, controls.PacketKey(client, seq))
	data, _ := abi.Unmarshal(rec.Packet.Payloads[0].Value)
	return data.Denom
}

// Route replacement on gno.land (ADR pr6375 §7.12, R18): a decision points the
// route at a new Ethereum client in constant work. Escrow, vouchers and
// controls stay keyed by the route key; denoms on the wire carry the current
// client id; the old client is retired in the core; the governance channel
// opens its next epoch over the new client.
func main(cur realm) {
	route := setupRoute(cur) // ethereum-1
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000)))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()

	send(cur, route, 1_000, 1_020, ethReceiver)
	recvOn(cur, "client-0", route, 1, weth, bob.String(), 500)
	advance(24 * time.Hour)
	transfer.Claim(cross(cur), route, voucher, 20)
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 2, ""))
	println("governance epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "last seq", ibcgov.LastSeq(1))

	// The new client: an Active Ethereum client with its counterparty.
	newClient := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	println("not registered yet:", revive(func() { govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, newClient)) }))
	core.RegisterCounterparty(cross(cur), newClient, [][]byte{{}}, "client-1")
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, newClient)))
	println("route client:", controlsView().Client(route), "| old retired:", core.IsClientRetired(route))
	println("governance epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "| epoch 1's seq 1 again:",
		revive(func() { ibcgov.Redispatch(cross(cur), 1, 1) }))

	// The old client carries nothing more.
	println("send over the old client:", revive(func() { send(cur, route, 100, 120, ethReceiver) }))
	println("receive over the old client:", recvOn(cur, "client-0", route, 2, weth, bob.String(), 1).Status)

	// The new client carries the route: same escrow, same vouchers.
	seq := send(cur, newClient, 1_000, 1_020, ethReceiver)
	println(transfer.Render("total_escrow/ugnot"))
	vseq := sendVoucher(cur, newClient, voucher, 100)
	println("voucher back: wire denom", wireDenom(route, newClient, vseq), "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))
	println("ugnot send on the wire:", wireDenom(route, newClient, seq))

	println("weth arriving on the new client:", recvOn(cur, "client-1", newClient, 1, weth, bob.String(), 300).Status)
	println("ugnot returning on the new client:", recvOn(cur, "client-1", newClient, 2, "transfer/client-1/ugnot", bob.String(), 200).Status)
	advance(24 * time.Hour)
	before := ugnot(bob)
	transfer.Claim(cross(cur), newClient, voucher, 20)
	transfer.Claim(cross(cur), newClient, "ugnot", 20)
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob), "| bob's ugnot +", ugnot(bob)-before)
	println(transfer.Render("total_escrow/ugnot"))
	println(transfer.Render("routes/" + route + "/claims"))
}

// Output:
// bob's vouchers: 490
// governance epoch 1 over ethereum-1 last seq 1
// not registered yet: ibcgov: ethereum-2 has no counterparty registered
// route client: ethereum-2 | old retired: true
// governance epoch 2 over ethereum-2 | epoch 1's seq 1 again: ibcgov: epoch 1 is past: its decisions are never sent again
// send over the old client: client ethereum-1 is an Ethereum client of no enrolled route: it carries no transfer
// receive over the old client: (2 gno.land/p/aib/ibc/types/v0.PacketStatus)
// {"denom":"ugnot","amount":2000,"clients":[{"client":"ethereum-1","amount":2000}]}
// voucher back: wire denom transfer/ethereum-2/0x457df1a9866af7b6a78eeba9291fc3e58b4d864b | bob's vouchers: 390
// ugnot send on the wire: ugnot
// weth arriving on the new client: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// ugnot returning on the new client: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// bob's vouchers: 680 | bob's ugnot + 180
// {"denom":"ugnot","amount":1800,"clients":[{"client":"ethereum-1","amount":1800}]}
// [{"key":"ethereum-1/00000000000000000001","denom":"ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE","to":"g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu","amount":500,"paid":500,"reduced":0,"state":"done","by":"packet","at":1237591895,"height":123,"seq":1},{"key":"ethereum-2/00000000000000000001","denom":"ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE","to":"g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu","amount":300,"paid":300,"reduced":0,"state":"done","by":"packet","at":1238283096,"height":123,"seq":2},{"key":"ethereum-2/00000000000000000002","denom":"ugnot","to":"g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu","amount":200,"paid":200,"reduced":0,"state":"done","by":"packet","at":1238283096,"height":123,"seq":1}]
