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
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
	"gno.land/r/nt/grc20reg/v0"
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

const weth = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"

// Every address a decision names is stored in its canonical, lowercase
// spelling (Codex round 7 #3): bech32 accepts the uppercase one and the
// banker credits the same account, but the GRC20 ledger, the fee collector
// and the seats compare strings. An uppercase sweep payee receives vouchers
// it can spend, an uppercase fee collector is stored lowercase, and an
// uppercase seat flags as its holder.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "")))
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()

	recv(cur, route, 1, weth, "not-an-address", 300)
	execute(cur, govern(cur, ibcgov.NewSweepRequest(cross(cur), route, controls.PacketKey(route, 1), strings.ToUpper(string(carol)))))
	e, _ := controlsView().Sweep(route, controls.PacketKey(route, 1))
	println("sweep paid to carol:", e.PaidTo == string(carol), "| carol's vouchers:", transfer.VoucherBalanceOf(voucher, carol))

	// The public voucher helpers too (Codex round 8 #4): an uppercase
	// recipient is credited under its canonical spelling, which can spend it,
	// and an uppercase spender's allowance is its canonical one's.
	testing.SetRealm(testing.NewUserRealm(carol))
	transfer.VoucherSend(cross(cur), voucher, address(strings.ToUpper(string(bob))), 40)
	transfer.VoucherApprove(cross(cur), voucher, address(strings.ToUpper(string(bob))), 10)
	testing.SetRealm(testing.NewUserRealm(bob))
	transfer.VoucherSend(cross(cur), voucher, carol, 15)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	token := grc20reg.Get(transfer.PkgPath + "." + transfer.VoucherSymbol(voucher))
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob), "| bob's allowance from carol:", token.Allowance(carol, bob),
		"| left under the uppercase spelling:", transfer.VoucherBalanceOf(voucher, address(strings.ToUpper(string(bob)))))

	execute(cur, govern(cur, ibcgov.NewSetFeeCollectorRequest(cross(cur), route, strings.ToUpper(string(alice)))))
	println("fee collector is alice:", strings.Contains(transfer.Render("routes/"+route), `"fee_collector":"`+string(alice)+`"`))

	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+strings.ToUpper(string(guardian)))))
	println("seat 0:", ibcgov.Seat(0) == guardian)
	testing.SetRealm(testing.NewUserRealm(guardian))
	ibcgov.SetFlag(cross(cur), route, ibcgov.FnRefunds, "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("flagged by its holder:", ibcgov.Flagged(route, ibcgov.FnRefunds))
	testing.SetRealm(testing.NewUserRealm(guardian))
	ibcgov.ClearFlag(cross(cur), route, ibcgov.FnRefunds)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	// The bridge contracts of an enrolment, spelled in uppercase.
	other := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), other, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), other, strings.ToUpper(string(collector)),
		"0x00000000000000000000000000000000000B0011 0x00000000000000000000000000000000000B0012 0x00000000000000000000000000000000000B0013")))
	page := transfer.Render("routes/" + other)
	println("protected, lowercase:", strings.Contains(page, `"0x00000000000000000000000000000000000b0011 router"`),
		"| fee collector:", strings.Contains(page, `"fee_collector":"`+string(collector)+`"`))

	// The admin builders' addresses too.
	execute(cur, govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), strings.ToUpper(string(bob)))))
	execute(cur, govern(cur, ibcgov.NewCoreAddMemberRequest(cross(cur), strings.ToUpper(string(bob)))))
	execute(cur, govern(cur, ibcgov.NewTransferAddMemberRequest(cross(cur), strings.ToUpper(string(bob)))))
	relayers := core.Relayers()
	println("relayer:", len(relayers) == 1 && relayers[0] == bob, "| core member:", core.IsAuthorityMember(bob),
		"| transfer member:", transfer.IsAuthorityMember(bob))
}

// Output:
// sweep paid to carol: true | carol's vouchers: 300
// bob's vouchers: 25 | bob's allowance from carol: 10 | left under the uppercase spelling: 0
// fee collector is alice: true
// seat 0: true
// flagged by its holder: true
// protected, lowercase: true | fee collector: true
// relayer: true | core member: true | transfer member: true
