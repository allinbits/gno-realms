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

func sendGRC20(cur realm, route string, amount int64) uint64 {
	return sendGRC20To(cur, route, amount, ethReceiver)
}

func sendGRC20To(cur realm, route string, amount int64, receiver string) uint64 {
	testing.SetRealm(testing.NewUserRealm(sender))
	_, seq := transfer.Transfer(cross(cur), route, receiver, token, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

// A GRC20 token on a route: the send takes the amount and the route fee from
// the sender's allowance (the fee goes to the collector), escrows the amount
// under the route key and records the send; a timeout refunds it under the
// refund meter; a return from Ethereum is a claim paid in installments.
func main(cur realm) {
	route := setupRoute(cur)
	alias := transfer.GRC20Alias(token)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, alias, "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))

	transferAddr := chain.PackageAddress(transfer.PkgPath)
	grc20test.Mint(cross(cur), sender, 5_000)
	grc20test.Approve(cross(cur), sender, transferAddr, 1_000)
	// Its GnoVoucher on Ethereum could never move what it receives (Codex
	// review #17).
	println("to its Ethereum token:", revive(func() { sendGRC20To(cur, route, 100, "0x0000000000000000000000000000000000C0FFEE") }))
	println("allowance below amount + fee:", revive(func() { sendGRC20(cur, route, 990) }))
	// revive keeps what ran before the abort (on chain the whole transaction
	// reverts): start again from fresh balances.
	grc20test.Mint(cross(cur), sender, 20)
	grc20test.Approve(cross(cur), sender, transferAddr, 1_000)
	collector0 := grc20test.BalanceOf(collector)
	seq := sendGRC20(cur, route, 980)
	println("sent", seq, "| sender", grc20test.BalanceOf(sender), "| collector +", grc20test.BalanceOf(collector)-collector0, "| realm", grc20test.BalanceOf(transferAddr))
	println(transfer.Render("total_escrow/" + alias))
	rec, _ := controlsView().Send(route, controls.PacketKey(route, seq))
	data, _ := abi.Unmarshal(rec.Packet.Payloads[0].Value)
	println("record:", rec.Denom == alias, rec.Amount, rec.Fee, "wire denom", data.Denom)

	// A timeout refunds the amount (the refund meter filled while the denom
	// was enabled 7 days ago).
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	if err := app.OnTimeoutPacket(cross(cur), route, "client-0", seq, rec.Packet.Payloads[0]); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("after the timeout: sender", grc20test.BalanceOf(sender), "| realm", grc20test.BalanceOf(transferAddr))

	// Send again, then the token comes back from Ethereum to alice.
	grc20test.Approve(cross(cur), sender, transferAddr, 1_000)
	sendGRC20(cur, route, 900)
	println("return:", recv(cur, route, 1, "transfer/client-0/"+alias, alice.String(), 500).Status)
	advance(24 * time.Hour)
	transfer.Claim(cross(cur), route, alias, 20)
	println("alice", grc20test.BalanceOf(alice), "| collector", grc20test.BalanceOf(collector))
	println(transfer.Render("total_escrow/" + alias))
}

// Output:
// to its Ethereum token: the receiver is the token itself
// allowance below amount + fee: send packet failed for payload #0 app "transfer": escrow GRC20 gno.land/r/aib/ibc/apps/testing/grc20test.TEST error: insufficient allowance
// sent 2 | sender 4000 | collector + 20 | realm 980
// {"denom":"gno.land:r:aib:ibc:apps:testing:grc20test.TEST","amount":980,"clients":[{"client":"ethereum-1","amount":980}]}
// record: true 980 20 wire denom gno.land:r:aib:ibc:apps:testing:grc20test.TEST
// after the timeout: sender 4000 | realm 980
// return: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// alice 480 | collector 80
// {"denom":"gno.land:r:aib:ibc:apps:testing:grc20test.TEST","amount":1380,"clients":[{"client":"ethereum-1","amount":1380}]}
