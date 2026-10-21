// PKGPATH: gno.land/r/aib/main
package main

import (
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
	bob       = testutils.TestAddress("bob")
)

const (
	weth = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"
	usdc = "0x1000000000000000000000000000000000203b0d"
)

// e18 is one 18-decimal token in base units.
const e18 uint256 = 1_000_000_000_000_000_000

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

func claim(cur realm, route, denom string) int {
	testing.SetRealm(testing.NewUserRealm(bob)) // anyone
	n := transfer.Claim(cross(cur), route, denom, 20)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return n
}

func status(r types.RecvPacketResult) string {
	if r.Status == types.PacketStatus_Success {
		return "success ack"
	}
	return "error ack"
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.Kind + ": " + d.State()
}

// mintConfig is a minted denom's limits in base units of an 18-decimal token:
// a day cap of 1000 tokens, a supply cap of a million, a fee of 0.001.
func mintConfig(decimals int) controls.DenomConfig {
	return controls.DenomConfig{Kind: controls.KindMint, CapFloor: 1000 * e18, SupplyCap: 1_000_000 * e18,
		Fee: e18 / 1000, FeeFloor: e18 / 1_000_000, RefundCap: 1000 * e18, Decimals: decimals}
}

// setDenom builds the governed configuration of an Ethereum token's voucher
// with decimals.
func setDenom(cur realm, route, token string, decimals int) ibcgov.Request {
	c := mintConfig(decimals)
	return ibcgov.NewSetDenomRequest(cross(cur), route, token, c.Kind, c.CapFloor, c.SupplyCap, c.Fee, c.FeeFloor, 0, 0, c.RefundCap, "", decimals)
}

// An ICS20 packet carries no token metadata, so governance names the
// decimals a minted denom's voucher is created with (ADR 0005, "Voucher
// decimals"): amounts stay base units. The decimals may change until the
// first receive creates the voucher (a 7-day change, like any loosening);
// from then on grc20 fixes them, and a configuration naming others is refused
// by the builder and by the transfer app alike. An unescrowed denom's token
// is gno-native and takes none.
func main(cur realm) {
	route := setupRoute(cur)
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()

	// Enabled with 18 decimals; changed before any receive: accepted, after
	// 7 days, in either direction.
	id := govern(cur, setDenom(cur, route, weth, 18))
	d, _ := ibcgov.Decision(id)
	println(d.Text)
	execute(cur, id)
	id = govern(cur, setDenom(cur, route, weth, 6))
	println("6 decimals before the first receive:", decided(id))
	execute(cur, id)
	c, _ := transfer.ExtView("controls").(controls.Reader).DenomConfig(route, voucher)
	println("configured:", c.Decimals, "voucher exists:", transfer.VoucherSymbol(voucher) != "")
	execute(cur, govern(cur, setDenom(cur, route, weth, 18)))

	// Out of grc20's range, and an unescrowed denom's token is not minted
	// here: refused when built.
	println("19 decimals:", revive(func() { setDenom(cur, route, weth, 19) }))
	println("-1 decimals:", revive(func() { setDenom(cur, route, weth, -1) }))
	println("ugnot with decimals:", revive(func() {
		ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee", 6)
	}))

	// The first receive creates the voucher with the configured decimals;
	// the amount is the packet's, in base units.
	println("receive 1 WETH:", status(recv(cur, route, 1, weth, bob.String(), e18)))
	advance(24 * time.Hour)
	println("claims paid:", claim(cur, route, voucher))
	println("bob holds:", strconv.FormatUint256(transfer.VoucherBalanceOf(voucher, bob), 10), "fee:", strconv.FormatUint256(transfer.VoucherBalanceOf(voucher, collector), 10))
	println(transfer.Render("voucher/" + voucher))

	// Once the voucher exists its decimals never change: refused by the
	// builder, and by the transfer app should a decision carry others (the
	// decision is spent). The same decimals pass with any other change.
	println("6 decimals after the first receive:", revive(func() { setDenom(cur, route, weth, 6) }))
	testing.SetRealm(testing.NewCodeRealm(transfer.IBCGovPath))
	println("decided anyway:", transfer.GovApply(cross(cur), controls.OpDenom, controls.Params{Route: route, Denom: voucher, Config: mintConfig(6)}.Encode()))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	id = govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 1000*e18, 2_000_000*e18, e18/1000, e18/1_000_000, 0, 0, 1000*e18, "", 18))
	execute(cur, id)
	println("a higher supply cap at 18 decimals:", decided(id))

	// A token configured without decimals: its voucher counts base units.
	execute(cur, govern(cur, setDenom(cur, route, usdc, 0)))
	voucherB := ics20.NewDenom(usdc, ics20.NewHop("transfer", route)).IBCDenom()
	println("receive 500 USDC:", status(recv(cur, route, 2, usdc, bob.String(), 500)))
	println(transfer.Render("voucher/" + voucherB))

	// The route's JSON names each denom's decimals.
	js := transfer.Render("routes/" + route)
	println("route JSON:", strings.Contains(js, `"remote":"","decimals":18,`), strings.Contains(js, `"remote":"","decimals":0,`))
}

// Output:
// denom on route ethereum-1: ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE kind=mint capFloor=1000000000000000000000 supplyCap=1000000000000000000000000 fee=1000000000000000 feeFloor=1000000000000 sendMax=0 sendMin=0 refundCap=1000000000000000000000 remoteToken=- decimals=18
// 6 decimals before the first receive: set denom: pending
// configured: 6 voucher exists: false
// 19 decimals: ibcgov: controls: a voucher has 0 to 18 decimals, not 19
// -1 decimals: ibcgov: controls: a voucher has 0 to 18 decimals, not -1
// ugnot with decimals: ibcgov: controls: an unescrowed denom's token is gno-native and takes no decimals
// receive 1 WETH: success ack
// claims paid: 1
// bob holds: 999000000000000000 fee: 1000000000000000
// {"denom":"ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE","grc20reg_key":"gno.land/r/aib/ibc/apps/transfer.IBC-1","name":"0x457df1a9866af7b6a78eeba9291fc3e58b4d864b","symbol":"IBC-1","decimals":18,"total_supply":"1000000000000000000"}
// 6 decimals after the first receive: ibcgov: the voucher of ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE exists with 18 decimals, which never change
// decided anyway: the voucher of ibc/2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE exists with 18 decimals, which never change
// a higher supply cap at 18 decimals: set denom: applied
// receive 500 USDC: success ack
// {"denom":"ibc/F61E88E597F98385A59D8390409F317E80CD10ACC19C8FB56EF6CB12E85A1DAB","grc20reg_key":"gno.land/r/aib/ibc/apps/transfer.IBC-2","name":"0x1000000000000000000000000000000000203b0d","symbol":"IBC-2","decimals":0,"total_supply":"0"}
// route JSON: true true
