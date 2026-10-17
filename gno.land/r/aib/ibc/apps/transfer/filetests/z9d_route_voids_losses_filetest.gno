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
)

const ethReceiver = "0x5f67a5398d91087d1b37a8a43436196a7830867f"

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

func state(route string, seq uint64) string {
	c, _ := controlsView().Claim(route, controls.PacketKey(route, seq))
	return c.State + " paid " + strconv.FormatInt(c.Paid, 10) + " of " + strconv.FormatInt(c.Amount, 10)
}

func totals(route string) string {
	t, _ := controlsView().Totals(route, "ugnot")
	return "owed " + strconv.FormatInt(t.Owed, 10) + " withheld " + strconv.FormatInt(t.Withheld, 10) +
		" swept " + strconv.FormatInt(t.Swept, 10) + " lost " + strconv.FormatInt(t.Lost, 10) +
		" unrecovered " + strconv.FormatInt(t.Unrecovered(), 10)
}

func recapitalize(cur realm, route string, id, amount int64) {
	testing.IssueCoins(chain.PackageAddress(transfer.PkgPath), chain.NewCoins(chain.NewCoin("ugnot", amount)))
	testing.SetRealm(testing.NewUserRealm(funder))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", amount)))
	transfer.Recapitalize(cross(cur), route, id)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func clearPayouts(cur realm, route string) {
	testing.SetRealm(testing.NewUserRealm(guardian))
	ibcgov.ClearFlag(cross(cur), route, ibcgov.FnPayouts)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// Voids, restores and the loss ledger (ADR pr6375 §7.9): a void named by a
// guardian's payouts flag applies at once; a forged void books what was paid
// as lost; a route with losses stays closed, whatever the flags, until a
// recapitalization, a reduction or an accepted deficit is decided.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(guardian))))
	send(cur, route, 20_000, 20_020, ethReceiver)

	recv(cur, route, 1, "transfer/client-0/ugnot", alice.String(), 3_000)
	recv(cur, route, 2, "transfer/client-0/ugnot", bob.String(), 2_000)
	recv(cur, route, 3, "transfer/client-0/ugnot", carol.String(), 10) // swept: below the fee
	recv(cur, route, 4, "transfer/client-0/ugnot", carol.String(), 4_000)
	advance(24 * time.Hour)
	transfer.Claim(cross(cur), route, "ugnot", 20)
	println("alice:", state(route, 1), "| bob:", state(route, 2), "| carol:", state(route, 4))

	// The guardian names alice's packet: its forged void applies at once.
	testing.SetRealm(testing.NewUserRealm(guardian))
	ibcgov.SetFlag(cross(cur), route, ibcgov.FnPayouts, controls.PacketKey(route, 1))
	voidA := govern(cur, ibcgov.NewVoidRequest(cross(cur), route, controls.PacketKey(route, 1), true, "inc-1"))
	println("void named:", decided(voidA))
	println("alice:", state(route, 1), "|", totals(route))
	println(transfer.Render("routes/" + route + "/losses"))
	// A forged void is final: only a withheld void is restored.
	println("restore forged:", revive(func() {
		ibcgov.NewRestoreRequest(cross(cur), route, controls.PacketKey(route, 1))
	}))

	// A loss without a restoring decision closes the route whatever the
	// flags: the guardian clears its own flag, payouts stay closed.
	clearPayouts(cur, route)
	advance(24 * time.Hour)
	println("payouts flagged:", ibcgov.Flagged(route, ibcgov.FnPayouts), "| closed:", controlsView().LossClosed(route),
		"| claims paid:", transfer.Claim(cross(cur), route, "ugnot", 20))

	// A void nobody named waits 7 days; restoring a withheld claim loosens,
	// so it waits 7 days too (Codex round 11 #2).
	voidC := govern(cur, ibcgov.NewVoidRequest(cross(cur), route, controls.PacketKey(route, 4), false, "inc-1"))
	println("void not named:", decided(voidC))
	execute(cur, voidC)
	println("carol:", state(route, 4), "|", totals(route))
	restore := govern(cur, ibcgov.NewRestoreRequest(cross(cur), route, controls.PacketKey(route, 4)))
	println("restore:", decided(restore), "| early:", revive(func() { ibcgov.Execute(cross(cur), restore) }))
	execute(cur, restore)
	println("restore:", decided(restore))
	println("carol:", state(route, 4), "|", totals(route))

	// Recapitalization: authorized by a decision, paid by anyone.
	execute(cur, govern(cur, ibcgov.NewRecapitalizeRequest(cross(cur), route, "ugnot", 2_000, "inc-1")))
	r, _ := controlsView().Recap(route, 1)
	println("recap:", r.ID, r.Amount, r.Paid)
	println("wrong amount:", revive(func() { recapitalize(cur, route, 1, 1_999) }))
	recapitalize(cur, route, 1, 2_000)
	r, _ = controlsView().Recap(route, 1)
	println("recap paid:", r.Paid, r.PaidBy == funder, "|", totals(route))
	println(transfer.Render("total_escrow/ugnot"))

	// An authorization whose funding fell through is revoked, at once, and
	// its payment refused (Codex round 2 #6).
	execute(cur, govern(cur, ibcgov.NewRecapitalizeRequest(cross(cur), route, "ugnot", 300, "inc-1")))
	println("revoke:", decided(govern(cur, ibcgov.NewRevokeRecapRequest(cross(cur), route, 2))))
	println("stale payment:", revive(func() { recapitalize(cur, route, 2, 300) }))
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	// An accepted deficit closes the rest; the route reopens.
	execute(cur, govern(cur, ibcgov.NewAcceptDeficitRequest(cross(cur), route, "ugnot", 500, "inc-1")))
	println(totals(route), "| closed:", controlsView().LossClosed(route))

	// A loss a reconciliation recognized, and a liability reduction against it.
	execute(cur, govern(cur, ibcgov.NewRecordLossRequest(cross(cur), route, "ethereum-1/00000000000000000099", "ugnot", 100, "ethereum", "inc-2", "forged-delivery")))
	println(totals(route))
	// The forged receive voided above has its loss booked: a recorded loss of
	// it is refused, so its payout is in the ledger once (Codex round 9 #3).
	again := govern(cur, ibcgov.NewRecordLossRequest(cross(cur), route, controls.PacketKey(route, 1), "ugnot", 2500, "gno", "inc-2", "forged-delivery"))
	execute(cur, again)
	println("the voided receive's loss recorded again:", decided(again), "|", totals(route))
	execute(cur, govern(cur, ibcgov.NewReduceRequest(cross(cur), route, controls.PacketKey(route, 4), 100, "inc-2")))
	println("carol:", state(route, 4), "|", totals(route))

	// Sweep entries are paid only by decision.
	execute(cur, govern(cur, ibcgov.NewSweepRequest(cross(cur), route, controls.PacketKey(route, 3), string(carol))))
	e, _ := controlsView().Sweep(route, controls.PacketKey(route, 3))
	println("sweep paid:", e.Paid, e.PaidTo == string(carol))

	// A credit by vote needs a packet received with a success ack.
	credit := govern(cur, ibcgov.NewCreditRequest(cross(cur), route, "ethereum-1/00000000000000000042", "ugnot", string(carol), 100))
	execute(cur, credit)
	println("credit:", decided(credit))
}

// Output:
// alice: open paid 2500 of 3000 | bob: done paid 2000 of 2000 | carol: open paid 2500 of 4000
// void named: applied - void
// alice: forged paid 2500 of 3000 | owed 1500 withheld 0 swept 10 lost 2500 unrecovered 2500
// {"entries":[{"key":"ethereum-1/00000000000000000001","direction":"recv","denom":"ugnot","amount":2500,"chain":"gno","incident":"inc-1","cause":"forged payout"}],"next":""}
// restore forged: ibcgov: ethereum-1/00000000000000000001 is no withheld claim
// payouts flagged: false | closed: true | claims paid: 0
// void not named: pending - queued 7 days
// carol: withheld paid 2500 of 4000 | owed 0 withheld 1500 swept 10 lost 2500 unrecovered 2500
// restore: pending - queued 7 days | early: ibcgov: decision 6 is due at 1238369495, not before
// restore: applied - restore
// carol: open paid 2500 of 4000 | owed 1500 withheld 0 swept 10 lost 2500 unrecovered 2500
// recap: 1 2000 false
// wrong amount: send exactly 2000ugnot in a direct call
// recap paid: true true | owed 1500 withheld 0 swept 10 lost 2500 unrecovered 500
// {"denom":"ugnot","amount":15000,"clients":[{"client":"ethereum-1","amount":15000}]}
// revoke: applied - revoke recap
// stale payment: no unpaid recapitalization 2 on route ethereum-1
// owed 1500 withheld 0 swept 10 lost 2500 unrecovered 500 | closed: false
// owed 1500 withheld 0 swept 10 lost 2600 unrecovered 600
// the voided receive's loss recorded again: spent - spent: controls: receive ethereum-1/00000000000000000001 is represented here: void it as forged or settle it (action 5) | owed 1500 withheld 0 swept 10 lost 2600 unrecovered 600
// carol: open paid 2500 of 3900 | owed 1400 withheld 0 swept 10 lost 2600 unrecovered 500
// sweep paid: true true
// credit: spent - spent: packet ethereum-1/00000000000000000042 was never received
