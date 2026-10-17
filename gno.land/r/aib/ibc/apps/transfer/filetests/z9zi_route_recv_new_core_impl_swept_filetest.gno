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
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
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
	guardian  = testutils.TestAddress("guardian-0")
	watch     = testutils.TestAddress("watch-4")
)

const (
	ethReceiver = "0x5f67a5398d91087d1b37a8a43436196a7830867f"
	weth        = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"
)

const v99Path = "gno.land/r/aib/ibc/core/impl/v99"

// registerV99 registers another core implementation, as if from its own
// realm, after the deployment.
func registerV99(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(v99Path))
	core.RegisterImpl(cross(cur), implv0.New, "v0", nil)
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

// A core implementation registered after the deployment is a bridge realm
// at once (Codex round 15 #2): a native return addressed to it is swept at
// receipt, and a claim booked to its address before it was registered is
// swept at payout, never paid to a realm with no withdrawal entry point,
// its earlier installments kept on the entry (Codex round 16 #1).
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	send(cur, route, 1_000, 1_020, ethReceiver) // a lock of 1000 ugnot
	v99 := chain.PackageAddress(v99Path)

	// Before the registration: an ordinary recipient, booked as a claim.
	println("ugnot 200 to v99's address:", status(recv(cur, route, 1, "transfer/client-0/ugnot", v99.String(), 200)))
	_, isClaim := controlsView().Claim(route, controls.PacketKey(route, 1))
	println("a claim:", isClaim)
	// An hour later its first installment is paid: the claim is paid in part.
	advance(time.Hour)
	println("claim an hour later:", claim(cur, route, "ugnot"), "| v99 holds", ugnot(v99))
	c, _ := controlsView().Claim(route, controls.PacketKey(route, 1))
	println("claim 1:", c.Paid, "of", c.Amount, c.State)

	registerV99(cur)
	println("registered:", core.RegisteredImplPaths())
	println("ugnot 300 to v99:", status(recv(cur, route, 2, "transfer/client-0/ugnot", v99.String(), 300)))
	e, ok := controlsView().Sweep(route, controls.PacketKey(route, 2))
	println("swept at receipt:", ok, e.Amount, e.Reason)
	_, isClaim = controlsView().Claim(route, controls.PacketKey(route, 2))
	println("a claim:", isClaim)

	// At payout the earlier claim's recipient is a bridge realm: moved to
	// the owed sweep, nothing paid.
	advance(24 * time.Hour)
	held := ugnot(v99)
	println("claim a day later:", claim(cur, route, "ugnot"), "| v99 received", ugnot(v99)-held)
	_, isClaim = controlsView().Claim(route, controls.PacketKey(route, 1))
	println("the earlier claim left:", !isClaim)
	println(transfer.Render("routes/" + route + "/sweeps"))
	tot, _ := controlsView().Totals(route, "ugnot")
	println("owed", tot.Owed, "| swept", tot.Swept)
}

// Output:
// ugnot 200 to v99's address: success ack
// a claim: true
// claim an hour later: 1 | v99 holds 84
// claim 1: 104 of 200 open
// registered: slice[("gno.land/r/aib/ibc/core/impl/v0" string),("gno.land/r/aib/ibc/core/impl/v1" string),("gno.land/r/aib/ibc/core/impl/v99" string)]
// ugnot 300 to v99: success ack
// swept at receipt: true 300 bridge realm
// a claim: false
// claim a day later: 0 | v99 received 0
// the earlier claim left: true
// {"entries":[{"key":"ethereum-1/00000000000000000001","denom":"ugnot","to":"g1zzy4djuac4g6lrugky35czv92pqhmxnv0j8exx","amount":96,"reduced":0,"reason":"bridge realm","height":123,"voided":false,"paid":false,"paid_to":"","from_claim":true,"claim_paid":104},{"key":"ethereum-1/00000000000000000002","denom":"ugnot","to":"g1zzy4djuac4g6lrugky35czv92pqhmxnv0j8exx","amount":300,"reduced":0,"reason":"bridge realm","height":123,"voided":false,"paid":false,"paid_to":""}],"next":""}
// owed 0 | swept 396
