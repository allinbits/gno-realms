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
	"gno.land/r/aib/ibc/apps/testing/grc20test"
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
)

const (
	ethReceiver = "0x5f67a5398d91087d1b37a8a43436196a7830867f"
	token       = "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug
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

func sendGRC20(cur realm, route string, amount uint256) uint64 {
	return sendGRC20To(cur, route, amount, ethReceiver)
}

func sendGRC20To(cur realm, route string, amount uint256, receiver string) uint64 {
	testing.SetRealm(testing.NewUserRealm(sender))
	_, seq := transfer.Transfer(cross(cur), route, receiver, token, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// A governed payout that a token or the banker would refuse is refused
// before anything changes (Codex docs round 9 #1): the decision is spent, the
// entitlement kept. A GRC20 sweep to the transfer realm itself (which the
// token refuses as a self-transfer) is refused by the builder, and by the
// transfer app if it reaches it; the entry stays owed and is paid to a valid
// payee afterwards.
func main(cur realm) {
	route := setupRoute(cur)
	alias := transfer.GRC20Alias(token)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, alias, "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	transferAddr := chain.PackageAddress(transfer.PkgPath)
	grc20test.Mint(cross(cur), sender, 5_000)
	grc20test.Approve(cross(cur), sender, transferAddr, 1_000)
	sendGRC20(cur, route, 900)

	// A return addressed to the transfer realm: an owed sweep entry.
	recv(cur, route, 1, "transfer/client-0/"+alias, transferAddr.String(), 500)
	key := controls.PacketKey(route, 1)
	e, _ := controlsView().Sweep(route, key)
	println("swept:", e.Amount, e.Reason)

	println("builder, payee the transfer realm:", revive(func() { ibcgov.NewSweepRequest(cross(cur), route, key, transferAddr.String()) }))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/ibcgov"))
	refusal := transfer.GovApply(cross(cur), controls.OpSweep, controls.Params{Route: route, Keys: []string{key}, To: transferAddr}.Encode())
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	e, _ = controlsView().Sweep(route, key)
	println("applied anyway:", refusal, "| entry still owed:", !e.Paid && !e.Voided, "| realm holds", grc20test.BalanceOf(transferAddr))

	pay := govern(cur, ibcgov.NewSweepRequest(cross(cur), route, key, alice.String()))
	execute(cur, pay)
	println("to alice:", decided(pay), "| alice", grc20test.BalanceOf(alice))
}

// Output:
// swept: 500 bridge realm
// builder, payee the transfer realm: ibcgov: a sweep pays out of the transfer realm, never to it
// applied anyway: cannot pay g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00: not a valid recipient other than the transfer realm | entry still owed: true | realm holds 900
// to alice: applied - sweep | alice 500
