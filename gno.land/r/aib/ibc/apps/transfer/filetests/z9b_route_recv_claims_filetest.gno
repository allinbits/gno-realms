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
	alice     = testutils.TestAddress("alice")
	bob       = testutils.TestAddress("bob")
	guardian  = testutils.TestAddress("guardian-0")
	watch     = testutils.TestAddress("watch-4")
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

func flag(cur realm, who address, route, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.SetFlag(cross(cur), route, fn, "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func unflag(cur realm, who address, route, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.ClearFlag(cross(cur), route, fn)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func claim(cur realm, route, denom string) int {
	testing.SetRealm(testing.NewUserRealm(bob)) // anyone
	n := transfer.Claim(cross(cur), route, denom, 20)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return n
}

// sendVoucher sends bob's vouchers back to Ethereum.
func sendVoucher(cur realm, route, receiver, voucher string, amount int64) uint64 {
	testing.SetRealm(testing.NewUserRealm(bob))
	_, seq := transfer.Transfer(cross(cur), route, receiver, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

func status(r types.RecvPacketResult) string {
	if r.Status == types.PacketStatus_Success {
		return "success ack"
	}
	return "error ack"
}

// Receives from Ethereum on a route (ADR pr6375 §7.1, §6.8): refused with an
// error ack before any state change, or booked as a claim (or a sweep entry)
// keyed by the packet, paid later by the permissionless Claim within the
// meters, which start empty and restart empty when a payouts flag clears.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "")))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(guardian)+",4:"+string(watch))))
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()

	// A lock of 1000 ugnot.
	send(cur, route, 1_000, 1_020, ethReceiver)

	println("unknown token:", status(recv(cur, route, 1, "0x1111111111111111111111111111111111111111", alice.String(), 5)))
	println("invalid receiver:", status(recv(cur, route, 2, "transfer/client-0/ugnot", "not-an-address", 5)))
	println("ugnot 300 to alice:", status(recv(cur, route, 3, "transfer/client-0/ugnot", alice.String(), 300)))
	println("ugnot 900 above the free lock:", status(recv(cur, route, 4, "transfer/client-0/ugnot", alice.String(), 900)))
	println("ugnot 10 below the fee:", status(recv(cur, route, 5, "transfer/client-0/ugnot", alice.String(), 10)))
	println("ugnot 50 to the transfer realm:", status(recv(cur, route, 6, "transfer/client-0/ugnot", chain.PackageAddress(transfer.PkgPath).String(), 50)))
	println("weth 3000 to bob:", status(recv(cur, route, 7, weth, bob.String(), 3_000)))
	println("weth past the supply cap:", status(recv(cur, route, 8, weth, bob.String(), 7_001)))
	flag(cur, watch, route, ibcgov.FnCredits)
	println("credits flagged:", status(recv(cur, route, 9, weth, bob.String(), 1)))
	unflag(cur, watch, route, ibcgov.FnCredits)
	println(transfer.Render("routes/" + route + "/claims"))
	println(transfer.Render("routes/" + route + "/sweeps"))

	// The meters start empty: nothing is paid at once.
	println("claim at once:", claim(cur, route, "ugnot"), claim(cur, route, voucher))
	// A day later: alice's 300 (fee 20 to the collector, 280 to her), and
	// bob's 3000 within the day cap of 4000 and his quarter of it (1000).
	advance(24 * time.Hour)
	aliceBefore, collectorBefore := ugnot(alice), ugnot(collector)
	println("claim a day later:", claim(cur, route, "ugnot"), claim(cur, route, voucher))
	println("alice +", ugnot(alice)-aliceBefore, "collector +", ugnot(collector)-collectorBefore)
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob), "collector's:", transfer.VoucherBalanceOf(voucher, collector))
	c, _ := controlsView().Claim(route, controls.PacketKey(route, 7))
	println("bob's claim:", c.Paid, "of", c.Amount, c.State)

	// A payouts flag stops payouts; clearing it restarts the meters empty.
	flag(cur, guardian, route, ibcgov.FnPayouts)
	advance(24 * time.Hour)
	println("claim under a payouts flag:", claim(cur, route, voucher))
	unflag(cur, guardian, route, ibcgov.FnPayouts)
	println("claim right after the flag cleared:", claim(cur, route, voucher))
	advance(6 * time.Hour)
	println("claim 6 hours later:", claim(cur, route, voucher))
	c, _ = controlsView().Claim(route, controls.PacketKey(route, 7))
	println("bob's claim:", c.Paid, "of", c.Amount, c.State)

	// A voucher going back to Ethereum is a burn: never paused by a sends
	// flag, never limited or charged.
	flag(cur, watch, route, ibcgov.FnSends)
	seq := sendVoucher(cur, route, ethReceiver, voucher, 500)
	rec, _ := controlsView().Send(route, controls.PacketKey(route, seq))
	println("voucher return under a sends flag:", seq, "kind", rec.Kind, "fee", rec.Fee, "bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))
	data, _ := abi.Unmarshal(rec.Packet.Payloads[0].Value)
	println("denom on the wire:", data.Denom)
	println("to the token itself:", revive(func() { sendVoucher(cur, route, weth, voucher, 1) }))
	println(transfer.Render("routes/" + route))
}

// Output:
// unknown token: error ack
// invalid receiver: success ack
// ugnot 300 to alice: success ack
// ugnot 900 above the free lock: success ack
// ugnot 10 below the fee: success ack
// ugnot 50 to the transfer realm: success ack
// weth 3000 to bob: success ack
// weth past the supply cap: error ack
// credits flagged: error ack
// [{"key":"ethereum-1/00000000000000000003","denom":"ugnot","to":"g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh","amount":300,"paid":0,"reduced":0,"state":"open","by":"packet","at":1237591895,"height":123,"seq":1},{"key":"ethereum-1/00000000000000000007","denom":"ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE","to":"g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu","amount":3000,"paid":0,"reduced":0,"state":"open","by":"packet","at":1237591895,"height":123,"seq":1}]
// [{"key":"ethereum-1/00000000000000000002","denom":"ugnot","to":"not-an-address","amount":5,"reduced":0,"reason":"invalid receiver","height":123,"voided":false,"paid":false,"paid_to":""},{"key":"ethereum-1/00000000000000000004","denom":"ugnot","to":"g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh","amount":900,"reduced":0,"reason":"above the free lock","height":123,"voided":false,"paid":false,"paid_to":""},{"key":"ethereum-1/00000000000000000005","denom":"ugnot","to":"g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh","amount":10,"reduced":0,"reason":"below the fee","height":123,"voided":false,"paid":false,"paid_to":""},{"key":"ethereum-1/00000000000000000006","denom":"ugnot","to":"g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00","amount":50,"reduced":0,"reason":"bridge realm","height":123,"voided":false,"paid":false,"paid_to":""}]
// claim at once: 0 0
// claim a day later: 1 1
// alice + 280 collector + 20
// bob's vouchers: 990 collector's: 10
// bob's claim: 1000 of 3000 open
// claim under a payouts flag: 0
// claim right after the flag cleared: 0
// claim 6 hours later: 1
// bob's claim: 1250 of 3000 open
// voucher return under a sends flag: 2 kind mint fee 0 bob's vouchers: 740
// denom on the wire: transfer/ethereum-1/0x457df1a9866af7b6a78eeba9291fc3e58b4d864b
// to the token itself: the receiver is the token itself
// {"route":"ethereum-1","client":"ethereum-1","replaced":[],"enrolled":1235777492,"activated":123,"closed":false,"loss_closed":false,"fee_collector":"g1vdhkcmr9vd6x7ujlta047h6lta047h6lsp3m50","refused_recipients":[],"unrecovered":0,"unresolved":0,"denoms":[{"denom":"ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE","kind":"mint","cap_floor":4000,"launch_cap_floor":4000,"supply_cap":10000,"fee":10,"fee_floor":1,"send_max":0,"send_min":0,"refund_cap":4000,"remote":"","meter":{"level":750,"at":1237786295,"epoch":1},"refund_meter":{"level":0,"at":1236987094},"waiting":1,"queued_refunds":0,"totals":{"credited":3000,"owed":1750,"withheld":0,"swept":0,"paid":1240,"fees":10,"sweep_paid":0,"outstanding":750,"returning":500,"sent":500,"send_fees":0,"refunded":0,"queued_refunds":0,"lost":0,"recapitalized":0,"reduced":0,"accepted":0,"unrecovered":0,"unresolved":0}},{"denom":"ugnot","kind":"unescrow","cap_floor":10000,"launch_cap_floor":10000,"supply_cap":0,"fee":20,"fee_floor":2,"send_max":25000,"send_min":40,"refund_cap":10000,"remote":"0x0000000000000000000000000000000000c0ffee","meter":{"level":9700,"at":1237678295,"epoch":0},"refund_meter":{"level":0,"at":1236382293},"waiting":0,"queued_refunds":0,"totals":{"credited":300,"owed":0,"withheld":0,"swept":965,"paid":280,"fees":20,"sweep_paid":0,"outstanding":0,"returning":0,"sent":1000,"send_fees":20,"refunded":0,"queued_refunds":0,"lost":0,"recapitalized":0,"reduced":0,"accepted":0,"unrecovered":0,"unresolved":0}}]}
