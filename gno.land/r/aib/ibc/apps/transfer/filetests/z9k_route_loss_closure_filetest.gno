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
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	sender    = testutils.TestAddress("sender")
	alice     = testutils.TestAddress("alice")
	bob       = testutils.TestAddress("bob")
	carol     = testutils.TestAddress("carol")
	funder    = testutils.TestAddress("funder")
	guardian  = testutils.TestAddress("guardian-0")
	guardian1 = testutils.TestAddress("guardian-1")
)

const (
	ethReceiver = "0x5f67a5398d91087d1b37a8a43436196a7830867f"
	weth        = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"
)

func returnVoucher(cur realm, route, voucher string, amount uint256) uint64 {
	testing.SetRealm(testing.NewUserRealm(bob))
	_, seq := transfer.Transfer(cross(cur), route, ethReceiver, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

// errorAck delivers an error acknowledgement of send seq as the core does.
func errorAck(cur realm, route string, seq uint64) {
	rec, _ := controlsView().Send(route, controls.PacketKey(route, seq))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	if err := app.OnAcknowledgementPacket(cross(cur), route, "client-0", seq, types.UniversalErrorAcknowledgement(), rec.Packet.Payloads[0]); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

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
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector), bridge)))
	advance(7*24*time.Hour + time.Second) // keeps the timeline of the goldens
	return clientID
}

// send transfers amount of ugnot from sender to an Ethereum receiver, sending
// coins with the call (the coins land at the transfer realm first).
func send(cur realm, route string, amount uint256, coins int64, receiver string) uint64 {
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
func recv(cur realm, route string, seq uint64, denom, receiver string, amount uint256) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatUint256(amount, 10), "0x5f67a5398d91087d1b37a8a43436196a7830867f", receiver, "")
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

func state(route string, seq uint64) string {
	c, _ := controlsView().Claim(route, controls.PacketKey(route, seq))
	return c.State + " paid " + strconv.FormatUint256(c.Paid, 10) + " of " + strconv.FormatUint256(c.Amount, 10)
}

func totals(route string) string {
	t, _ := controlsView().Totals(route, "ugnot")
	return "owed " + strconv.FormatUint256(t.Owed, 10) + " withheld " + strconv.FormatUint256(t.Withheld, 10) +
		" swept " + strconv.FormatUint256(t.Swept, 10) + " lost " + strconv.FormatUint256(t.Lost, 10) +
		" unrecovered " + strconv.FormatUint256(t.Unrecovered(), 10)
}

func recapitalize(cur realm, route string, id int64, amount uint256) {
	testing.IssueCoins(chain.PackageAddress(transfer.PkgPath), chain.NewCoins(chain.NewCoin("ugnot", int64(amount))))
	testing.SetRealm(testing.NewUserRealm(funder))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", int64(amount))))
	transfer.Recapitalize(cross(cur), route, id)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func flag(cur realm, g address, route, keys string) {
	testing.SetRealm(testing.NewUserRealm(g))
	ibcgov.SetFlag(cross(cur), route, ibcgov.FnPayouts, keys)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func unflag(cur realm, g address, route string) {
	testing.SetRealm(testing.NewUserRealm(g))
	ibcgov.ClearFlag(cross(cur), route, ibcgov.FnPayouts)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// A route with a loss that has no restoring decision is closed by the
// transfer app itself, independently of the guardians' flags (ADR pr6375
// §7.9, Codex review #11): the guardians may clear their flags, ending the
// hold that would defer the 7-day restoring decision, without reopening the
// route; and a guardian whose seat is vacated takes its flag along without
// reopening it either.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee", 0)))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "", 0)))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(guardian)+",1:"+string(guardian1))))
	send(cur, route, 20_000, 20_020, ethReceiver)
	pending := send(cur, route, 1_000, 1_020, ethReceiver) // in flight across the loss
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()
	recv(cur, route, 9, weth, bob.String(), 500)
	advance(24 * time.Hour)
	transfer.Claim(cross(cur), route, voucher, 20)
	recv(cur, route, 1, "transfer/client-0/ugnot", alice.String(), 3_000)
	recv(cur, route, 2, "transfer/client-0/ugnot", bob.String(), 2_000)
	recv(cur, route, 3, "transfer/client-0/ugnot", carol.String(), 2_000)
	advance(24 * time.Hour)
	transfer.Claim(cross(cur), route, "ugnot", 1) // alice's first installment

	// Both guardians flag payouts: a hold. Alice's forged void, named, lands.
	flag(cur, guardian, route, controls.PacketKey(route, 1))
	flag(cur, guardian1, route, "")
	println("held:", ibcgov.Held())
	println("void:", decided(govern(cur, ibcgov.NewVoidRequest(cross(cur), route, controls.PacketKey(route, 1), true, "inc-1"))))
	recap := govern(cur, ibcgov.NewRecapitalizeRequest(cross(cur), route, "ugnot", 2_500, "inc-1"))

	// The guardians clear their flags: the hold ends a day later, but the
	// route stays closed while its loss has no restoring decision.
	unflag(cur, guardian, route)
	unflag(cur, guardian1, route)
	advance(25 * time.Hour)
	println("held:", ibcgov.Held(), "| flagged:", ibcgov.Flagged(route, ibcgov.FnPayouts), "| closed:", controlsView().LossClosed(route),
		"| claims paid:", transfer.Claim(cross(cur), route, "ugnot", 20))
	// The loss stops new exposure only (Codex round 2 #4): no gno-native send,
	// but voucher returns and refunds go on, under the refund meter alone.
	println("gno-native send:", revive(func() { send(cur, route, 100, 120, ethReceiver) }))
	testing.SetOriginSend(nil) // the aborted send left its envelope set
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	vouchers := transfer.VoucherBalanceOf(voucher, bob)
	returnVoucher(cur, route, voucher, 100)
	println("voucher return: bob's vouchers", vouchers, "->", transfer.VoucherBalanceOf(voucher, bob))
	before := ugnot(sender)
	errorAck(cur, route, pending)
	rec, _ := controlsView().Send(route, controls.PacketKey(route, pending))
	println("refund:", rec.Payment, "| sender +", ugnot(sender)-before)

	// The restoring decision is no longer deferred.
	execute(cur, recap)
	recapitalize(cur, route, 1, 2_500)
	println("recapitalized | closed:", controlsView().LossClosed(route), "| claims paid:", transfer.Claim(cross(cur), route, "ugnot", 20))

	// A second loss; the guardian flagging it leaves its seat: the flag goes,
	// the route stays closed until the deficit is accepted.
	advance(24 * time.Hour)
	flag(cur, guardian, route, controls.PacketKey(route, 2))
	println("void:", decided(govern(cur, ibcgov.NewVoidRequest(cross(cur), route, controls.PacketKey(route, 2), true, "inc-2"))))
	vacate := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"))
	execute(cur, vacate)
	println("vacate:", decided(vacate))
	advance(24 * time.Hour)
	println("flagged:", ibcgov.Flagged(route, ibcgov.FnPayouts), "| closed:", controlsView().LossClosed(route),
		"| claims paid:", transfer.Claim(cross(cur), route, "ugnot", 20))
	execute(cur, govern(cur, ibcgov.NewAcceptDeficitRequest(cross(cur), route, "ugnot", 2_000, "inc-2")))
	println("accepted | closed:", controlsView().LossClosed(route), "| claims paid:", transfer.Claim(cross(cur), route, "ugnot", 20))
}

// Output:
// held: true
// void: applied - void
// held: false | flagged: false | closed: true | claims paid: 0
// gno-native send: route ethereum-1 has a loss without a restoring decision: it takes no gno-native send
// voucher return: bob's vouchers 490 -> 390
// refund: paid | sender + 1000
// recapitalized | closed: false | claims paid: 2
// void: applied - void
// vacate: applied - seats 0
// flagged: false | closed: true | claims paid: 0
// accepted | closed: false | claims paid: 0
