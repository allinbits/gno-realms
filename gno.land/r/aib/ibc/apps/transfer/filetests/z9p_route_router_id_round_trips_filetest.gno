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
	"gno.land/r/aib/ibc/apps/testing/grc20test"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
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
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", clientID+" "+string(collector)+" "+bridge)))
	advance(7*24*time.Hour + time.Second) // the separate enrollment's delay, kept so the timeline stays
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

// recvFrom delivers a packet from the router client src to dst, as the core
// does after verifying its proof.
func recvFrom(cur realm, src, dst string, seq uint64, denom, receiver string, amount int64) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatInt(amount, 10), ethReceiver, receiver, "")
	bz, _ := abi.Marshal(data)
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), src, dst, seq, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return res
}

const denoms = "ugnot unescrow 10000 0 20 2 25000 40 10000 0x0000000000000000000000000000000000c0ffee;" +
	"gno.land:r:aib:ibc:apps:testing:grc20test.TEST unescrow 10000 0 20 2 25000 40 10000 0x0000000000000000000000000000000000c0fffe"

// GNOT and a GRC20 token go to Ethereum and come back over routes whose
// router client ids are a suffixless custom id, one of 65 characters and one
// of 128 (Codex round 4 #2, class C): the packets pass validation both ways,
// the returning denoms ("transfer/<router id>/<base>") are parsed with their
// hop, and the escrow is released by the claims.
func main(cur realm) {
	alias := transfer.GRC20Alias(token)
	transferAddr := chain.PackageAddress(transfer.PkgPath)
	for i, remote := range []string{"gnoland", "gnoland." + strings.Repeat("x", 57), "gnoland." + strings.Repeat("y", 120)} {
		client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
		core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, remote)
		if i == 0 {
			execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1",
				client+" "+string(collector)+" "+bridge+": "+denoms)))
		} else {
			execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(collector), bridge)))
			for _, spec := range strings.Split(denoms, ";") {
				f := strings.Fields(spec)
				execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), client, f[0], f[1], 10000, 0, 20, 2, 25000, 40, 10000, f[9])))
			}
		}
		send(cur, client, 1_000, 1_020, ethReceiver)
		grc20test.Mint(cross(cur), sender, 1_020)
		grc20test.Approve(cross(cur), sender, transferAddr, 1_020)
		sendGRC20(cur, client, 1_000)

		back := recvFrom(cur, remote, client, 1, "transfer/"+remote+"/ugnot", alice.String(), 500)
		backGRC20 := recvFrom(cur, remote, client, 2, "transfer/"+remote+"/"+alias, alice.String(), 500)
		advance(24 * time.Hour)
		before := ugnot(alice)
		transfer.Claim(cross(cur), client, "ugnot", 20)
		transfer.Claim(cross(cur), client, alias, 20)
		println(len(remote), "characters:", back.Status == types.PacketStatus_Success, backGRC20.Status == types.PacketStatus_Success,
			"| alice +", ugnot(alice)-before, "ugnot, holds", grc20test.BalanceOf(alice), "TEST")
	}
}

// Output:
// 7 characters: true true | alice + 480 ugnot, holds 480 TEST
// 65 characters: true true | alice + 480 ugnot, holds 960 TEST
// 128 characters: true true | alice + 480 ugnot, holds 1440 TEST
