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
	carol     = testutils.TestAddress("carol")
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

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

func claimState(route string, seq uint64) string {
	c, _ := controlsView().Claim(route, controls.PacketKey(route, seq))
	return c.State + " paid " + strconv.FormatInt(c.Paid, 10)
}

// Route replacement on gno.land (ADR pr6375 §7.12, R18): a decision points the
// route at a new Ethereum client in constant work. Escrow, vouchers and
// controls stay keyed by the route key; denoms on the wire carry the current
// client id; the old client is retired in the core; the governance channel
// opens its next epoch over the new client. The route closes with the
// replacement (no send, credit, claim payout or refund payout): the
// reconciliation settles the old client's sends, a restoring decision answers
// its loss, a withheld claim is restored, and only a governed reopening opens
// the route again (Codex review #3).
func main(cur realm) {
	route := setupRoute(cur) // ethereum-1
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000)))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()

	send(cur, route, 1_000, 1_020, ethReceiver)
	recvOn(cur, "client-0", route, 1, weth, bob.String(), 500)
	recvOn(cur, "client-0", route, 2, weth, carol.String(), 300)
	// Carol's claim is suspect: withheld, it stays booked and restorable.
	execute(cur, govern(cur, ibcgov.NewVoidRequest(cross(cur), route, controls.PacketKey(route, 2), false, "inc-1")))
	transfer.Claim(cross(cur), route, voucher, 20)
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob), "| carol:", claimState(route, 2))
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 2, ""))
	println("governance epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "last seq", ibcgov.LastSeq(1))

	// The new client: an Active Ethereum client with its counterparty.
	newClient := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	println("not registered yet:", revive(func() { govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, newClient)) }))
	core.RegisterCounterparty(cross(cur), newClient, [][]byte{{}}, "client-1")
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, newClient)))
	println("route client:", controlsView().Client(route), "| old retired:", core.IsClientRetired(route), "| closed:", controlsView().Closed(route))
	println("governance epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "| epoch 1's seq 1 again:",
		revive(func() { ibcgov.Redispatch(cross(cur), 1, 1) }))

	// The old client carries nothing more.
	println("send over the old client:", revive(func() { send(cur, route, 100, 120, ethReceiver) }))
	println("receive over the old client:", recvOn(cur, "client-0", route, 3, weth, bob.String(), 1).Status)

	// Closed: the new client carries nothing either until the reopening.
	println("send over the new client:", revive(func() { send(cur, newClient, 1_000, 1_020, ethReceiver) }))
	println("receive over the new client:", recvOn(cur, "client-1", newClient, 1, weth, bob.String(), 300).Status)
	println("claims paid:", transfer.Claim(cross(cur), newClient, voucher, 20))

	// The reconciliation: the old client's send was delivered, but a refund
	// overpaid on it is a loss; carol's claim is genuine and restored.
	settle := govern(cur, ibcgov.NewSettleRequest(cross(cur), route, route, "1:4:20", "inc-1"))
	execute(cur, settle)
	println("settle:", decided(settle))
	rec, _ := controlsView().Send(route, controls.PacketKey(route, 1))
	println("send 1 settled as", rec.Settlement, "| unresolved:", controlsView().Unresolved(route))
	again := govern(cur, ibcgov.NewSettleRequest(cross(cur), route, route, "1:3:0", "inc-1"))
	execute(cur, again)
	println("settle again:", decided(again))
	println("restore:", decided(govern(cur, ibcgov.NewRestoreRequest(cross(cur), route, controls.PacketKey(route, 2)))))
	early := govern(cur, ibcgov.NewReopenRouteRequest(cross(cur), route))
	execute(cur, early)
	println("reopen with the loss unresolved:", decided(early))
	execute(cur, govern(cur, ibcgov.NewAcceptDeficitRequest(cross(cur), route, "ugnot", 20, "inc-1")))
	reopen := govern(cur, ibcgov.NewReopenRouteRequest(cross(cur), route))
	execute(cur, reopen)
	println("reopen:", decided(reopen), "| closed:", controlsView().Closed(route))

	// Reopened, the new client carries the route: same escrow, same vouchers.
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
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob), "| bob's ugnot +", ugnot(bob)-before, "| carol:", claimState(route, 2))
	println(transfer.Render("total_escrow/ugnot"))
}

// Output:
// bob's vouchers: 490 | carol: withheld paid 0
// governance epoch 1 over ethereum-1 last seq 1
// not registered yet: ibcgov: ethereum-2 has no counterparty registered
// route client: ethereum-2 | old retired: true | closed: true
// governance epoch 2 over ethereum-2 | epoch 1's seq 1 again: ibcgov: epoch 1 is past: its decisions are never sent again
// send over the old client: client ethereum-1 is an Ethereum client of no enrolled route: it carries no transfer
// receive over the old client: (2 gno.land/p/aib/ibc/types/v0.PacketStatus)
// send over the new client: route ethereum-1 is closed until a governed reopening: it carries no send
// receive over the new client: (2 gno.land/p/aib/ibc/types/v0.PacketStatus)
// claims paid: 0
// settle: applied - settle
// send 1 settled as 4 | unresolved: 20
// settle again: spent - spent: controls: item 0: send ethereum-1/00000000000000000001 is settled already
// restore: applied - restore
// reopen with the loss unresolved: spent - spent: controls: route ethereum-1 has 20 of losses without a restoring decision (recapitalization, reduction or accepted deficit)
// reopen: applied - reopen | closed: false
// {"denom":"ugnot","amount":2000,"clients":[{"client":"ethereum-1","amount":2000}]}
// voucher back: wire denom transfer/ethereum-2/0x457df1a9866af7b6a78eeba9291fc3e58b4d864b | bob's vouchers: 390
// ugnot send on the wire: ugnot
// weth arriving on the new client: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// ugnot returning on the new client: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// bob's vouchers: 680 | bob's ugnot + 180 | carol: done paid 300
// {"denom":"ugnot","amount":1800,"clients":[{"client":"ethereum-1","amount":1800}]}
