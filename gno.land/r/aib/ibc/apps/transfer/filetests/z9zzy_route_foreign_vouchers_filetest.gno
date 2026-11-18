// PKGPATH: gno.land/r/aib/main
package main

import (
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
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
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

// sendAs sends 100 of denom from bob over route to an Ethereum receiver.
func sendAs(cur realm, route, denom string) {
	testing.SetRealm(testing.NewUserRealm(bob))
	transfer.Transfer(cross(cur), route, "0x5f67a5398d91087d1b37a8a43436196a7830867f", denom, 100, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// chainRoute enrols a client of chain id as a route.
func chainRoute(cur realm, id uint64) string {
	cs := ethtesting.ClientState()
	cs.ChainID = id
	c := core.CreateClient(cross(cur), cs, ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), c, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), c, string(collector), bridge)))
	return c
}

func setDenom(cur realm, route, denom, kind string) string {
	r := revive(func() {
		if kind == "mint" {
			govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, denom, kind, 4_000, 10_000, 10, 1, 0, 0, 4_000, "", 0))
		} else {
			govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, denom, kind, 4_000, 0, 10, 1, 1_000, 1, 4_000, "0x00000000000000000000000000000000000c0001", 0))
		}
	})
	if r == nil {
		return "accepted"
	}
	return r.(string)
}

// A voucher of one route is never a denom of another (ADR 0007): route B
// refuses route A's voucher by its IBC denom, by its GRC20 registry key and
// by its alias, and refuses any key of the voucher namespace before it is
// allocated; a raw IBC denom is taken only for a voucher of the route's own;
// and the send path refuses a voucher's GRC20 on any route.
func main(cur realm) {
	a := chainRoute(cur, 1)
	b := chainRoute(cur, 2)
	const token = "0x1000000000000000000000000000000000203b0d"
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), a, token, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "", 0)))
	voucher := ics20.NewDenom(token, ics20.NewHop("transfer", a)).IBCDenom()
	// A key of the namespace before any voucher exists.
	next := transfer.GRC20Alias(transfer.PkgPath) + ".IBC-1"
	println("B, a voucher key not allocated yet:", setDenom(cur, b, next, "unescrow"))
	println("B, a raw IBC denom not allocated:", setDenom(cur, b, voucher, "mint"))
	println("receive on A:", status(recv(cur, a, 1, token, bob.String(), 500)))
	advance(24 * time.Hour)
	println("claims paid:", claim(cur, a, voucher), "| bob holds", transfer.VoucherBalanceOf(voucher, bob))
	key := transfer.PkgPath + "." + transfer.VoucherSymbol(voucher)
	println("B, A's voucher by its IBC denom:", setDenom(cur, b, voucher, "mint"))
	println("B, A's voucher by its registry key:", setDenom(cur, b, key, "unescrow"))
	println("B, A's voucher by its alias:", setDenom(cur, b, transfer.GRC20Alias(key), "unescrow"))
	println("B, the key allocated since:", setDenom(cur, b, next, "unescrow"))
	println("A, its own voucher by its IBC denom:", setDenom(cur, a, voucher, "mint"))
	// The transfer app checks again when the configuration applies, below
	// ibcgov's checks: the same configurations, applied directly as ibcgov,
	// are refused there too.
	mint := controls.Params{Route: b, Denom: voucher, Config: controls.DenomConfig{Kind: "mint", CapFloor: 4_000, SupplyCap: 10_000, Fee: 10, FeeFloor: 1, RefundCap: 4_000}}
	escrow := controls.Params{Route: b, Denom: transfer.GRC20Alias(key), Config: controls.DenomConfig{Kind: "unescrow", CapFloor: 4_000, Fee: 10, FeeFloor: 1, SendMax: 1_000, SendMin: 1, RefundCap: 4_000, Remote: "0x00000000000000000000000000000000000c0001"}}
	testing.SetRealm(testing.NewCodeRealm(ibcgov.PkgPath))
	r1 := transfer.GovApply(cross(cur), controls.OpDenom, mint.Encode())
	testing.SetRealm(testing.NewCodeRealm(ibcgov.PkgPath))
	r2 := transfer.GovApply(cross(cur), controls.OpDenom, escrow.Encode())
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("applied directly, A's voucher on B:", r1)
	println("applied directly, A's voucher alias on B:", r2)
	// A voucher leaves only by its IBC denom, over its own route.
	println("send A's voucher as a GRC20 over A:", revive(func() { sendAs(cur, a, key) }))
	println("send A's voucher as a GRC20 over B:", revive(func() { sendAs(cur, b, key) }))
	println("send A's voucher over B:", revive(func() { sendAs(cur, b, voucher) }))
}

// Output:
// B, a voucher key not allocated yet: ibcgov: gno.land:r:aib:ibc:apps:transfer.IBC-1 is in the voucher namespace: a voucher is configured as a minted denom on its own route only
// B, a raw IBC denom not allocated: ibcgov: ibc/F61E88E597F98385A59D8390409F317E80CD10ACC19C8FB56EF6CB12E85A1DAB is no voucher allocated to route ethereum-2: name a new minted denom by its token's address
// receive on A: success ack
// claims paid: 1 | bob holds 490
// B, A's voucher by its IBC denom: ibcgov: ibc/F61E88E597F98385A59D8390409F317E80CD10ACC19C8FB56EF6CB12E85A1DAB is no voucher allocated to route ethereum-2: name a new minted denom by its token's address
// B, A's voucher by its registry key: ibcgov: gno.land/r/aib/ibc/apps/transfer.IBC-1 is in the voucher namespace: a voucher is configured as a minted denom on its own route only
// B, A's voucher by its alias: ibcgov: gno.land:r:aib:ibc:apps:transfer.IBC-1 is in the voucher namespace: a voucher is configured as a minted denom on its own route only
// B, the key allocated since: ibcgov: gno.land:r:aib:ibc:apps:transfer.IBC-1 is in the voucher namespace: a voucher is configured as a minted denom on its own route only
// A, its own voucher by its IBC denom: accepted
// applied directly, A's voucher on B: ibc/F61E88E597F98385A59D8390409F317E80CD10ACC19C8FB56EF6CB12E85A1DAB is a voucher of transfer/ethereum-1/0x1000000000000000000000000000000000203b0d, not of route ethereum-2
// applied directly, A's voucher alias on B: gno.land:r:aib:ibc:apps:transfer.IBC-1 is in the voucher namespace: a voucher is a minted denom of its own route only
// send A's voucher as a GRC20 over A: gno.land/r/aib/ibc/apps/transfer.IBC-1 is a voucher: send it by its ibc/ denom, over the route it came from
// send A's voucher as a GRC20 over B: gno.land/r/aib/ibc/apps/transfer.IBC-1 is a voucher: send it by its ibc/ denom, over the route it came from
// send A's voucher over B: voucher ibc/F61E88E597F98385A59D8390409F317E80CD10ACC19C8FB56EF6CB12E85A1DAB did not come over route ethereum-2
