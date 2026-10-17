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
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
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

// registerVerifier registers a verifier version from the verifiers
// namespace realm at path.
func registerVerifier(cur realm, path string) {
	testing.SetRealm(testing.NewCodeRealm(path))
	core.RegisterVerifier(cross(cur), ethereum.ClientType, ethtesting.NextVersion, []string{ethereum.Version}, ethtesting.ToNextVerifier)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func swept(route string, seq uint64) string {
	e, ok := controlsView().Sweep(route, controls.PacketKey(route, seq))
	if !ok {
		return "not swept"
	}
	return "swept " + strconv.FormatInt(e.Amount, 10) + " (" + e.Reason + ", paid before " + strconv.FormatInt(e.ClaimPaid, 10) + ")"
}

// A verifier version's registering realm is a bridge realm from its
// registration on, for good (Codex round 23 #1): a native return addressed
// to it is swept at receipt, and a claim to it, unpaid or paid in part, is
// swept at payout, never paid to a realm with no withdrawal entry point.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	send(cur, route, 1_000, 1_020, ethReceiver) // a lock of 1000 ugnot
	const (
		before  = "gno.land/r/aib/ibc/core/verifiers/before"
		between = "gno.land/r/aib/ibc/core/verifiers/between"
		partial = "gno.land/r/aib/ibc/core/verifiers/partial"
	)
	to := func(p string) string { return chain.PackageAddress(p).String() }

	// Registered before the receive: swept at receipt.
	registerVerifier(cur, before)
	println("to a registered verifier realm:", status(recv(cur, route, 1, "transfer/client-0/ugnot", to(before), 100)), "|", swept(route, 1))

	// Credited as a claim, then registered before its payout.
	println("before registration:", status(recv(cur, route, 2, "transfer/client-0/ugnot", to(between), 100)), "|", swept(route, 2))
	registerVerifier(cur, between)

	// Credited and paid in part, then registered.
	recv(cur, route, 3, "transfer/client-0/ugnot", to(partial), 200)
	advance(time.Hour)
	claim(cur, route, "ugnot")
	c, _ := controlsView().Claim(route, controls.PacketKey(route, 3))
	println("paid in part:", c.Paid, "of", c.Amount, "| it holds", ugnot(chain.PackageAddress(partial)))
	registerVerifier(cur, partial)

	advance(24 * time.Hour)
	held := ugnot(chain.PackageAddress(between)) + ugnot(chain.PackageAddress(partial))
	println("claim after the registrations:", claim(cur, route, "ugnot"), "| they received", ugnot(chain.PackageAddress(between))+ugnot(chain.PackageAddress(partial))-held)
	println("between:", swept(route, 2), "| partial:", swept(route, 3))
}

// Output:
// to a registered verifier realm: success ack | swept 100 (bridge realm, paid before 0)
// before registration: success ack | not swept
// paid in part: 104 of 200 | it holds 84
// claim after the registrations: 0 | they received 0
// between: swept 100 (bridge realm, paid before 0) | partial: swept 96 (bridge realm, paid before 104)
