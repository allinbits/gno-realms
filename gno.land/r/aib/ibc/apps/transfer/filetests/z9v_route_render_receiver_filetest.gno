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
const bridge = "0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

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

// An owed sweep entry keeps the raw receiver a packet named, so its page
// shows what an attacker wrote (ADR pr6375 §6.8; Codex round 6 #6): the JSON
// pages are inert in Markdown, every character that could make a link, an
// image or raw HTML written as an escape, and a path segment echoed in an
// error is escaped the same way.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	send(cur, route, 5_000, 5_020, ethReceiver)

	const evil = "[claim refund](https://attacker.example) <img src=x> `x` **y**"
	recv(cur, route, 1, "transfer/client-0/ugnot", evil, 300)
	e, _ := controlsView().Sweep(route, controls.PacketKey(route, 1))
	println("kept raw:", e.To == evil)
	page := transfer.Render("routes/" + route + "/sweeps")
	println(page)
	println("active markdown on the page:", strings.ContainsAny(page[strings.Index(page, `"to":`):strings.Index(page, `,"amount"`)], "[]()<>`*"))
	println(core.Render("clients/" + route + "/packet_commitments/[x](https:attacker)"))
	println(transfer.Render("denoms/ibc/[x](https:attacker)"))
}

// Output:
// kept raw: true
// [{"key":"ethereum-1/00000000000000000001","denom":"ugnot","to":"\u005bclaim refund\u005d\u0028https://attacker.example\u0029 \u003cimg src=x\u003e \u0060x\u0060 \u002a\u002ay\u002a\u002a","amount":300,"reduced":0,"reason":"invalid receiver","height":123,"voided":false,"paid":false,"paid_to":""}]
// active markdown on the page: false
// {"error":"invalid sequence \"\u005bx\u005d\u0028https:attacker\u0029\": strconv.ParseUint: parsing \"\u005bx\u005d\u0028https:attacker\u0029\": invalid syntax"}
// {"error":"denom ibc/\u005bx\u005d\u0028https:attacker\u0029 not found"}
