// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
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

// A receive naming a receiver that is no gno.land address (ADR pr6375 §6.8,
// §7.1, Codex review #20) is not refunded at its source: it is acknowledged
// as a success and booked as an owed sweep entry keeping the raw receiver,
// paid only by a 7-day decision naming the payee.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	send(cur, route, 5_000, 5_020, ethReceiver)

	res := recv(cur, route, 1, "transfer/client-0/ugnot", "cosmos1notgnoland", 300)
	e, _ := controlsView().Sweep(route, controls.PacketKey(route, 1))
	t, _ := controlsView().Totals(route, "ugnot")
	println("status:", res.Status == types.PacketStatus_Success, "| sweep:", e.To, e.Amount, e.Reason, "| swept", t.Swept)
	println("a claim pays nothing:", transfer.Claim(cross(cur), route, "ugnot", 20))

	// A blank receiver is no address either: an owed sweep with a success
	// acknowledgement, not a refusal (Codex round 12 #5).
	for i, blank := range []string{"", "   "} {
		seq := uint64(10 + i)
		res := recv(cur, route, seq, "transfer/client-0/ugnot", blank, 50)
		e, _ := controlsView().Sweep(route, controls.PacketKey(route, seq))
		println("receiver", strconv.Quote(blank)+":", res.Status == types.PacketStatus_Success, "| sweep:", strconv.Quote(e.To), e.Amount, e.Reason)
	}

	// A receiver written in gnoweb's own inline syntax, TeX math and a
	// mention, is kept raw and rendered inert: no $ or @ reaches the page
	// (Codex round 28 #2).
	recv(cur, route, 12, "transfer/client-0/ugnot", "$x$ $$y$$ @alice", 50)
	page := transfer.Render("routes/" + route + "/sweeps")
	println("math or mention on the page:", strings.ContainsAny(page, "$@"))

	pay := govern(cur, ibcgov.NewSweepRequest(cross(cur), route, controls.PacketKey(route, 1), string(carol)))
	println("before the delay:", decided(pay))
	before := ugnot(carol)
	execute(cur, pay)
	e, _ = controlsView().Sweep(route, controls.PacketKey(route, 1))
	println("paid:", decided(pay), "| carol +", ugnot(carol)-before, "| entry paid to", e.PaidTo == string(carol))
}

// Output:
// status: true | sweep: cosmos1notgnoland 300 invalid receiver | swept 300
// a claim pays nothing: 0
// receiver "": true | sweep: "" 50 invalid receiver
// receiver "   ": true | sweep: "   " 50 invalid receiver
// math or mention on the page: false
// before the delay: pending - queued 7 days
// paid: applied - sweep | carol + 300 | entry paid to true
