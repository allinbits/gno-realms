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
	bob       = testutils.TestAddress("bob")
	carol     = testutils.TestAddress("carol")
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

// recvOn delivers a packet arriving on client dst from the router client src.
func recvOn(cur realm, src, dst string, seq uint64, denom, receiver string, amount uint256) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatUint256(amount, 10), ethReceiver, receiver, "")
	bz, _ := abi.Marshal(data)
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), src, dst, seq, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return res
}

func sendVoucher(cur realm, client, voucher string, amount uint256) uint64 {
	testing.SetRealm(testing.NewUserRealm(bob))
	_, seq := transfer.Transfer(cross(cur), client, ethReceiver, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

func wireDenom(route, client string, seq uint64) string {
	rec, _ := controlsView().Send(route, controls.PacketKey(client, seq))
	data, _ := abi.Unmarshal(rec.Packet.Payloads[0].Value)
	return data.Denom
}

// meters reads the route's bridge meter and bob's meter of denom now.
func meters(route, denom string) string {
	epoch, at := ibcgov.PayoutsEpoch(route)
	b, r := controlsView().Meters(route, denom, bob, time.Now().Unix(), epoch, at, 0)
	return "bridge " + strconv.FormatUint256(b, 10) + ", bob " + strconv.FormatUint256(r, 10)
}

// sendBack is the home page's "send back" action of the voucher (its link
// names the client the return goes through).
func sendBack() string {
	for _, line := range strings.Split(transfer.Render(""), "\n") {
		if i := strings.Index(line, "send back"); i >= 0 {
			j := strings.Index(line[i:], " — ")
			return line[i : i+j]
		}
	}
	return "none"
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

func claimState(route string, seq uint64) string {
	c, _ := controlsView().Claim(route, controls.PacketKey(route, seq))
	return c.State + " paid " + strconv.FormatUint256(c.Paid, 10)
}

// Route replacement on gno.land (ADR pr6375 §7.12, R18): a decision points the
// route at a new Ethereum client in constant work. Escrow, vouchers and
// controls stay keyed by the route key; denoms on the wire carry the current
// client id; the old client is retired in the core; the governance channel
// opens its next epoch over the new client. The route closes with the
// replacement (no send, credit, claim payout or refund payout): the
// reconciliation settles the old client's sends, a restoring decision answers
// its loss, a withheld claim is restored, and only a governed reopening opens
// the route again (Codex review #3).
func main(cur realm) {
	route := setupRoute(cur) // ethereum-1
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "")))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()

	send(cur, route, 1_000, 1_020, ethReceiver)
	recvOn(cur, "client-0", route, 1, weth, bob.String(), 500)
	recvOn(cur, "client-0", route, 2, weth, carol.String(), 300)
	// Carol's claim is suspect: withheld, it stays booked and restorable.
	execute(cur, govern(cur, ibcgov.NewVoidRequest(cross(cur), route, controls.PacketKey(route, 2), false, "inc-1")))
	transfer.Claim(cross(cur), route, voucher, 20)
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob), "| carol:", claimState(route, 2))
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 2, ""))
	println("governance epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "last seq", ibcgov.LastSeq(1))

	// The new client: an Active Ethereum client with its counterparty.
	// The Ethereum router received the old client's send 1 and acknowledged
	// it as a success: the replacement client's state proves it.
	sent1, _ := controlsView().Send(route, controls.PacketKey(route, 1))
	router := ethtesting.NewRouter()
	router.CommitReceipt(sent1.Packet)
	router.CommitAcknowledgement(sent1.Packet, types.Acknowledgement{AppAcknowledgements: [][]byte{[]byte(`{"result":"AQ=="}`)}})
	newClient := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	println("not registered yet:", revive(func() { govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, newClient, 1)) }))
	core.RegisterCounterparty(cross(cur), newClient, [][]byte{{}}, "client-1")
	replace := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, newClient, 1))
	advance(7*24*time.Hour + time.Second)
	println("meters before the migration:", meters(route, voucher))
	ibcgov.Execute(cross(cur), replace)
	println("route client:", controlsView().Client(route), "| old retired for transfers:", core.IsClientRetiredFor(route, "transfer"), "| for good:", core.IsClientRetired(route), "| closed:", controlsView().Closed(route))
	// Every meter starts empty after a migration, then refills (Codex review #10).
	println("meters after the migration:", meters(route, voucher))
	advance(6 * time.Hour)
	println("six hours later:", meters(route, voucher))
	// The governance epoch stays over the old client until IBCAdmin's epoch
	// notice arrives over the new one (z9zv): its decision in flight is not
	// sent again while a packet of it is out.
	println("governance epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "| epoch 1's seq 1 again:",
		revive(func() { ibcgov.Redispatch(cross(cur), 1, 1) }))

	// The old client carries nothing more.
	println("send over the old client:", revive(func() { send(cur, route, 100, 120, ethReceiver) }))
	println("receive over the old client:", recvOn(cur, "client-0", route, 3, weth, bob.String(), 1).Status)

	// Rendered returns no longer name the retired client (Codex review #18),
	// nor does any other send choice (round 2 #7).
	println("send back while closed:", sendBack())
	for _, line := range strings.Split(transfer.Render(""), "\n") {
		if strings.HasPrefix(line, "- `"+route+"` — ") || strings.HasPrefix(line, "- [send via `"+route+"`]") {
			println("client choice:", line[:strings.Index(line, ", trusted")])
		}
	}

	// Closed: the new client carries nothing either until the reopening,
	// except a voucher return (exit only: it lowers the supply and adds no
	// exposure).
	println("send over the new client:", revive(func() { send(cur, newClient, 1_000, 1_020, ethReceiver) }))
	testing.SetOriginSend(nil)
	held := transfer.VoucherBalanceOf(voucher, bob)
	closedReturn := sendVoucher(cur, newClient, voucher, 50)
	println("voucher back while closed: wire denom", wireDenom(route, newClient, closedReturn), "| bob's vouchers:", held, "->", transfer.VoucherBalanceOf(voucher, bob))
	println("receive over the new client:", recvOn(cur, "client-1", newClient, 1, weth, bob.String(), 300).Status)
	println("claims paid:", transfer.Claim(cross(cur), newClient, voucher, 20))

	// The old client's send is still open: no reopening before it is settled.
	early := govern(cur, ibcgov.NewReopenRouteRequest(cross(cur), route))
	execute(cur, early)
	println("reopen with a send open:", decided(early))

	// The reconciliation: the old client's send was delivered; a collision
	// is a loss; carol's claim is genuine and restored.
	unproven := govern(cur, ibcgov.NewSettleRequest(cross(cur), route, route, "1:3:0", "inc-1"))
	execute(cur, unproven)
	println("settle before the proof:", decided(unproven))
	transfer.ProveOutcome(cross(cur), sent1.Packet, types.NewHeight(0, 72), router.Proof(), router.Proof())
	proven, _ := controlsView().Send(route, controls.PacketKey(route, 1))
	println("proven outcome:", proven.Proven, "at", proven.ProvenAt)
	settle := govern(cur, ibcgov.NewSettleRequest(cross(cur), route, route, "1:3:0", "inc-1"))
	execute(cur, settle)
	println("settle:", decided(settle))
	rec, _ := controlsView().Send(route, controls.PacketKey(route, 1))
	println("send 1 settled as", rec.Settlement)
	again := govern(cur, ibcgov.NewSettleRequest(cross(cur), route, route, "1:3:0", "inc-1"))
	execute(cur, again)
	println("settle again:", decided(again))
	execute(cur, govern(cur, ibcgov.NewRecordLossRequest(cross(cur), route, "ethereum-1/00000000000000000009", "ugnot", 20, "gno", "inc-1", "collision")))
	restore := govern(cur, ibcgov.NewRestoreRequest(cross(cur), route, controls.PacketKey(route, 2)))
	execute(cur, restore)
	println("restore:", decided(restore))
	println("unresolved:", controlsView().Unresolved(route))

	// The reopening records the loss as an accepted deficit.
	reopen := govern(cur, ibcgov.NewReopenRouteRequest(cross(cur), route))
	execute(cur, reopen)
	t, _ := controlsView().Totals(route, "ugnot")
	println("reopen:", decided(reopen), "| closed:", controlsView().Closed(route), "| accepted", t.Accepted, "unrecovered", t.Unrecovered())

	println("send back after the reopening:", sendBack())

	// Reopened, the new client carries the route: same escrow, same vouchers.
	seq := send(cur, newClient, 1_000, 1_020, ethReceiver)
	println(transfer.Render("total_escrow/ugnot"))
	vseq := sendVoucher(cur, newClient, voucher, 100)
	println("voucher back: wire denom", wireDenom(route, newClient, vseq), "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))
	println("ugnot send on the wire:", wireDenom(route, newClient, seq))

	println("weth arriving on the new client:", recvOn(cur, "client-1", newClient, 1, weth, bob.String(), 300).Status)
	println("ugnot returning on the new client:", recvOn(cur, "client-1", newClient, 2, "transfer/client-1/ugnot", bob.String(), 200).Status)
	advance(24 * time.Hour)
	before := ugnot(bob)
	transfer.Claim(cross(cur), newClient, voucher, 20)
	transfer.Claim(cross(cur), newClient, "ugnot", 20)
	println("bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob), "| bob's ugnot +", ugnot(bob)-before, "| carol:", claimState(route, 2))
	println(transfer.Render("total_escrow/ugnot"))
}

// Output:
// bob's vouchers: 490 | carol: withheld paid 0
// governance epoch 1 over ethereum-1 last seq 1
// not registered yet: ibcgov: ethereum-2 has no counterparty registered
// meters before the migration: bridge 4000, bob 1000
// route client: ethereum-2 | old retired for transfers: true | for good: false | closed: true
// meters after the migration: bridge 0, bob 0
// six hours later: bridge 1000, bob 250
// governance epoch 1 over ethereum-1 | epoch 1's seq 1 again: ibcgov: decision 1 is not re-dispatchable (sent as packet 2)
// send over the old client: client ethereum-1 is an Ethereum client of no enrolled route: it carries no transfer
// receive over the old client: (2 gno.land/p/aib/ibc/types/v0.PacketStatus)
// send back while closed: send back](/r/aib/main$help&func=Transfer&amount=&clientID=ethereum-2&denom=ibc%2F2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE&memo=&receiver=&timeoutTimestamp=1238826697) via `ethereum-2`
// client choice: - `ethereum-1` — retired
// send over the new client: route ethereum-1 is closed until a governed reopening: it carries no gno-native send
// voucher back while closed: wire denom transfer/ethereum-2/0x457df1a9866af7b6a78eeba9291fc3e58b4d864b | bob's vouchers: 490 -> 440
// receive over the new client: (2 gno.land/p/aib/ibc/types/v0.PacketStatus)
// claims paid: 0
// reopen with a send open: spent - spent: controls: 1 send records of retired client ethereum-1 are still open: settle them first
// settle before the proof: spent - spent: controls: item 0: action 3 does not match send ethereum-1/00000000000000000001's proven outcome (0)
// proven outcome: 1 at 72
// settle: applied - settle
// send 1 settled as 3
// settle again: spent - spent: controls: item 0: send ethereum-1/00000000000000000001 is settled already
// restore: applied - restore
// unresolved: 20
// reopen: applied - reopen | closed: false | accepted 20 unrecovered 20
// send back after the reopening: send back](/r/aib/main$help&func=Transfer&amount=&clientID=ethereum-2&denom=ibc%2F2495500BDD01666856D26EE034DB2F940FD4DA91239F4D5C7AE1E9D07538CFFE&memo=&receiver=&timeoutTimestamp=1243060304) via `ethereum-2`
// {"denom":"ugnot","amount":"2000","clients":[{"client":"ethereum-1","amount":"2000"}]}
// voucher back: wire denom transfer/ethereum-2/0x457df1a9866af7b6a78eeba9291fc3e58b4d864b | bob's vouchers: 340
// ugnot send on the wire: ugnot
// weth arriving on the new client: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// ugnot returning on the new client: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// bob's vouchers: 630 | bob's ugnot + 180 | carol: done paid 300
// {"denom":"ugnot","amount":"1800","clients":[{"client":"ethereum-1","amount":"1800"}]}
