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
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

var (
	collector = testutils.TestAddress("collector")
	sender    = testutils.TestAddress("sender")
	bob       = testutils.TestAddress("bob")
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
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", clientID, string(collector), "", 10_000)))
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

func refundState(client string, seq uint64) string {
	r, ok := controlsView().Send(client, controls.PacketKey(client, seq))
	if !ok {
		return "no record"
	}
	return "outcome " + r.Outcome + ", payment " + r.Payment + ", refunded " + strconv.FormatInt(r.Refunded, 10) +
		", backfilled " + strconv.FormatBool(r.Backfilled)
}

// returnVoucher sends amount of bob's vouchers back to Ethereum.
func returnVoucher(cur realm, client, voucher string, amount int64) (types.MsgSendPacket, uint64) {
	testing.SetRealm(testing.NewUserRealm(bob))
	packet, seq := transfer.Transfer(cross(cur), client, ethReceiver, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return packet, seq
}

func backfill(cur realm, p types.Packet) {
	testing.SetRealm(testing.NewUserRealm(sender)) // anyone
	transfer.Backfill(cross(cur), p)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// Every send on an Ethereum route has a record, so every refund there goes
// through the refund meter and the refunds hold (ADR pr6375 §7.13, Codex
// review #1). Vouchers impl/v0 minted, and returns impl/v0 sent before the
// upgrade, are not exempt: an acknowledgement or a timeout of a send without
// a record is refused until anyone backfills it from the commitment the core
// still holds. The upgrade's own decision stages the route and its denoms,
// so a voucher impl/v0 minted goes back at once after it, recorded.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	println("impl:", transfer.ImplVersion(), "| receive:", recv(cur, client, 1, weth, bob.String(), 100).Status)
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", client)).IBCDenom()
	// Two returns sent under impl/v0, in flight across the upgrade.
	msg1, seq1 := returnVoucher(cur, client, voucher, 40)
	msg2, seq2 := returnVoucher(cur, client, voucher, 20)
	timeout := msg1.TimeoutTimestamp
	p1 := types.NewPacket(seq1, client, "client-0", timeout, msg1.Payloads[0])
	p2 := types.NewPacket(seq2, client, "client-0", msg2.TimeoutTimestamp, msg2.Payloads[0])
	println("bob's vouchers under v0:", transfer.VoucherBalanceOf(voucher, bob))

	// One decision switches to impl/v1 with the route and its denom staged
	// (Codex round 3 #6): the controls and the route take effect together.
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1",
		client, string(collector), weth+" mint 4000 10000 10 1 0 0 4000 -", 4000)))
	t, _ := controlsView().Totals(client, voucher)
	println("impl:", transfer.ImplVersion(), "| denoms on the route:", len(controlsView().Denoms(client)), "| outstanding at enable:", t.Outstanding)

	// A voucher minted by impl/v0 goes back at once, recorded and metered.
	_, now := returnVoucher(cur, client, voucher, 10)
	rec, recorded := controlsView().Send(client, controls.PacketKey(client, now))
	println("return right after the upgrade:", recorded, rec.Kind, rec.Amount, "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	println("timeout before the backfill:", app.OnTimeoutPacket(cross(cur), client, "client-0", seq1, p1.Payloads[0]))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	forged := p1
	forged.TimeoutTimestamp++
	println("backfill of another packet:", revive(func() { backfill(cur, forged) }))
	backfill(cur, p1)
	backfill(cur, p2)
	println("again:", revive(func() { backfill(cur, p1) }))
	t, _ = controlsView().Totals(client, voucher)
	println("backfilled:", refundState(client, seq1), "| returning", t.Returning)

	// The timeout's refund waits under the refund meter (it starts empty).
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	if err := app.OnTimeoutPacket(cross(cur), client, "client-0", seq1, p1.Payloads[0]); err != nil {
		panic(err)
	}
	ack := types.NewResultAppAcknowledgement([]byte{byte(1)})
	if err := app.OnAcknowledgementPacket(cross(cur), client, "client-0", seq2, ack.MarshalJSON(), p2.Payloads[0]); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("timed out:", refundState(client, seq1), "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))
	println("acknowledged:", refundState(client, seq2))
	advance(24 * time.Hour)
	transfer.ClaimRefunds(cross(cur), client, voucher, 20)
	t, _ = controlsView().Totals(client, voucher)
	println("claimed:", refundState(client, seq1), "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob),
		"| outstanding", t.Outstanding, "returning", t.Returning)
}

// Output:
// impl: v0 | receive: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// bob's vouchers under v0: 40
// impl: v1 | denoms on the route: 1 | outstanding at enable: 40
// return right after the upgrade: true mint 10 | bob's vouchers: 30
// timeout before the backfill: send ethereum-1/00000000000000000001 has no record: backfill it first (transfer.Backfill)
// backfill of another packet: the packet differs from the one the core committed
// again: controls: a send record exists for ethereum-1/00000000000000000001
// backfilled: outcome , payment , refunded 0, backfilled true | returning 70
// timed out: outcome timeout, payment queued, refunded 0, backfilled true | bob's vouchers: 30
// acknowledged: outcome success, payment , refunded 0, backfilled true
// claimed: outcome timeout, payment claimed, refunded 40, backfilled true | bob's vouchers: 70 | outstanding 70 returning 10
