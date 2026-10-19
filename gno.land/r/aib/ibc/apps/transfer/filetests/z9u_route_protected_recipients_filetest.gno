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
	watch     = testutils.TestAddress("watch-4")
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
	// The governance channel is bound before any replacement (one is
	// refused until then), over the route's original client; its 7 days
	// keep the timeline of the goldens.
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), clientID)))
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

// The route's bridge contracts are protected recipients from its activation
// on (ADR pr6375 R12, §7.8; Codex round 6 #5): with no refusal decided, a
// send to the router, the ICS20 transfer, IBCAdmin or any of the route's
// voucher tokens is refused; an unrefuse decision does not lift them, and
// they stay through a replacement.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ufoo", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffef")))
	for _, a := range []string{"0x1d95d544586eacb63b6154e9e45122b32ded11aa", "0x00000000000000000000000000000000000B0002", "0x00000000000000000000000000000000000b0003", "0x0000000000000000000000000000000000c0ffef"} {
		println(a, revive(func() { send(cur, route, 100, 120, a) }))
	}
	println("an ordinary receiver:", send(cur, route, 100, 120, ethReceiver))

	execute(cur, govern(cur, ibcgov.NewUnrefuseRecipientsRequest(cross(cur), route, "0x1d95d544586eacb63b6154e9e45122b32ded11aa")))
	println("after an unrefuse:", revive(func() { send(cur, route, 100, 120, "0x1d95d544586eacb63b6154e9e45122b32ded11aa") }))

	newClient := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), newClient, [][]byte{{}}, "client-1")
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, newClient, 1)))
	println("after a replacement:", controlsView().IsRefused(route, "0x1d95d544586eacb63b6154e9e45122b32ded11aa"),
		controlsView().IsRefused(route, "0x00000000000000000000000000000000000b0003"))
}

// Output:
// 0x1d95d544586eacb63b6154e9e45122b32ded11aa the receiver is a contract of the bridge
// 0x00000000000000000000000000000000000B0002 the receiver is a contract of the bridge
// 0x00000000000000000000000000000000000b0003 the receiver is a contract of the bridge
// 0x0000000000000000000000000000000000c0ffef the receiver is a contract of the bridge
// an ordinary receiver: 1
// after an unrefuse: the receiver is a contract of the bridge
// after a replacement: true true
