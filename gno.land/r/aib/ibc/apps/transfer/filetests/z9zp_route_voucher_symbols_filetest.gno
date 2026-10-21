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
func sendVoucher(cur realm, route, receiver, voucher string, amount uint256) uint64 {
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

// Two Ethereum tokens whose voucher hashes share their first 11 hex
// characters (ground offline) both get usable vouchers (Codex round 27 #1):
// a voucher's registry symbol is allocated from a counter, not taken from
// its hash, so no denom can take another's registry key.
func main(cur realm) {
	route := setupRoute(cur)
	const (
		tokenA = "0x1000000000000000000000000000000000203b0d"
		tokenB = "0x1000000000000000000000000000000000691bd4"
	)
	for _, tok := range []string{tokenA, tokenB} {
		execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, tok, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "")))
	}
	voucherA := ics20.NewDenom(tokenA, ics20.NewHop("transfer", route)).IBCDenom()
	voucherB := ics20.NewDenom(tokenB, ics20.NewHop("transfer", route)).IBCDenom()
	println("same 11-character prefix:", voucherA[4:15] == voucherB[4:15], voucherA[4:15])
	println("receive A:", status(recv(cur, route, 1, tokenA, bob.String(), 500)))
	println("receive B:", status(recv(cur, route, 2, tokenB, bob.String(), 500)))
	println("symbols:", transfer.VoucherSymbol(voucherA), transfer.VoucherSymbol(voucherB))
	advance(24 * time.Hour)
	println("claims paid:", claim(cur, route, voucherA), claim(cur, route, voucherB))
	println("bob holds:", transfer.VoucherBalanceOf(voucherA, bob), transfer.VoucherBalanceOf(voucherB, bob))
}

// Output:
// same 11-character prefix: true F61E88E597F
// receive A: success ack
// receive B: success ack
// symbols: IBC-1 IBC-2
// claims paid: 1 1
// bob holds: 490 490
