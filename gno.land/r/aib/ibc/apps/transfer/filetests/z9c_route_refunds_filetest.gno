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
	execute(cur, govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1")))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector))))
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

// ack delivers an acknowledgement of a recorded send to the transfer app as
// the core does after verifying it; timeout likewise a timeout.
func ack(cur realm, route string, seq uint64, ack []byte) {
	rec, _ := controlsView().Send(route, controls.PacketKey(route, seq))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	if err := app.OnAcknowledgementPacket(cross(cur), route, "client-0", seq, ack, rec.Packet.Payloads[0]); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func timeout(cur realm, route string, seq uint64) {
	rec, _ := controlsView().Send(route, controls.PacketKey(route, seq))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	if err := app.OnTimeoutPacket(cross(cur), route, "client-0", seq, rec.Packet.Payloads[0]); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func claimRefunds(cur realm, route string) int {
	n := transfer.ClaimRefunds(cross(cur), route, "ugnot", 20)
	return n
}

func record(route string, seq uint64) string {
	r, _ := controlsView().Send(route, controls.PacketKey(route, seq))
	return r.Outcome + "/" + r.Payment + " refunded " + strconv.FormatInt(r.Refunded, 10) + " at height " + strconv.FormatInt(r.ProcessedHeight, 10)
}

// Refunds on a route (ADR pr6375 §7.13, §7.3): acknowledgements and timeouts
// are always processed and attached to the send record; a refund is paid at
// once within the refund meter, queued beyond it and paid by the
// permissionless ClaimRefunds as the meter refills, and only queued under a
// refunds hold, never cancelled.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 2_400, "0x0000000000000000000000000000000000c0ffee")))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "4:"+string(watch))))
	// The refund meter started empty when the denom was enabled, 7 days ago:
	// it is full now (2400).
	s1 := send(cur, route, 1_000, 1_020, ethReceiver)
	s2 := send(cur, route, 2_000, 2_020, ethReceiver)
	s3 := send(cur, route, 1_500, 1_520, ethReceiver)
	s4 := send(cur, route, 600, 620, ethReceiver)

	ack(cur, route, s1, []byte(`{"result":"AQ=="}`))
	println("success:", record(route, s1))

	before := ugnot(sender)
	ack(cur, route, s2, types.UniversalErrorAcknowledgement())
	println("error ack within the meter:", record(route, s2), "sender +", ugnot(sender)-before)

	before = ugnot(sender)
	timeout(cur, route, s3)
	println("timeout beyond the meter:", record(route, s3), "sender +", ugnot(sender)-before)

	// A refunds hold queues everything and pays nothing.
	testing.SetRealm(testing.NewUserRealm(watch))
	ibcgov.SetFlag(cross(cur), route, ibcgov.FnRefunds, "")
	advance(24 * time.Hour)
	timeout(cur, route, s4)
	println("timeout under a refunds hold:", record(route, s4))
	println("claim under a refunds hold:", claimRefunds(cur, route))

	// Lifted: the queue pays in order as the meter allows.
	testing.SetRealm(testing.NewUserRealm(watch))
	ibcgov.ClearFlag(cross(cur), route, ibcgov.FnRefunds)
	before = ugnot(sender)
	println("claim after the hold:", claimRefunds(cur, route), "sender +", ugnot(sender)-before)
	println("s3:", record(route, s3))
	println("s4:", record(route, s4))
	advance(24 * time.Hour)
	before = ugnot(sender)
	println("claim a day later:", claimRefunds(cur, route), "sender +", ugnot(sender)-before)
	println("s3:", record(route, s3))
	println("s4:", record(route, s4))
	println(transfer.Render("total_escrow/ugnot"))
	println("a settled send again:", revive(func() { timeout(cur, route, s3) }))
}

// Output:
// success: success/ refunded 0 at height 123
// error ack within the meter: error/paid refunded 2000 at height 123 sender + 2000
// timeout beyond the meter: timeout/queued refunded 0 at height 123 sender + 0
// timeout under a refunds hold: timeout/queued refunded 0 at height 123
// claim under a refunds hold: 0
// claim after the hold: 2 sender + 2100
// s3: timeout/claimed refunded 1500 at height 123
// s4: timeout/claimed refunded 600 at height 123
// claim a day later: 0 sender + 0
// s3: timeout/claimed refunded 1500 at height 123
// s4: timeout/claimed refunded 600 at height 123
// {"denom":"ugnot","amount":1000,"clients":[{"client":"ethereum-1","amount":1000}]}
// a settled send again: controls: send ethereum-1/00000000000000000003 is settled already (timeout)
