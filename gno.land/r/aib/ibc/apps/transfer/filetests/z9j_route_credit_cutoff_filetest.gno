// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"strconv"
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
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
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", clientID, string(collector), bridge, "", 10_000)))
	advance(7*24*time.Hour + time.Second) // the separate enrollment's delay, kept so the timeline stays
	return clientID
}

// ethPacket is a transfer packet the Ethereum router sent to client.
func ethPacket(client string, seq uint64, token, receiver string, amount int64, timeout uint64) types.Packet {
	data := ics20.NewFungibleTokenPacketData(token, strconv.FormatInt(amount, 10), ethReceiver, receiver, "")
	bz, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	return types.Packet{
		Sequence: seq, SourceClient: "client-0", DestinationClient: client, TimeoutTimestamp: timeout,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}},
	}
}

// relay delivers p through the core with a proof of the router's commitment.
func relay(cur realm, router *ethtesting.Router, p types.Packet) {
	core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet: p, ProofHeight: types.NewHeight(0, 72), Ext: extproof.Proof{Data: router.Proof()},
	})
}

func controlsView() controls.Reader { return transfer.ExtView("controls").(controls.Reader) }

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// A receive impl/v0 paid at once, before the route's activation, keeps its
// receipt and success acknowledgement, but a credit by vote of it is refused:
// it would pay the packet twice. A receive the controls booked as a sweep
// entry is credited (Codex review #2).
func main(cur realm) {
	const client = "ethereum-1"
	timeout := uint64(time.Now().Add(90 * 24 * time.Hour).Unix())
	p1 := ethPacket(client, 1, weth, bob.String(), 900, timeout)
	p2 := ethPacket(client, 2, weth, chain.PackageAddress(transfer.PkgPath).String(), 50, timeout) // a bridge realm: swept
	p3 := ethPacket(client, 3, ethReceiver, bob.String(), 70, timeout)                             // a denom not enabled: error ack
	router := ethtesting.NewRouter()
	router.CommitPacket(p1)
	router.CommitPacket(p2)
	router.CommitPacket(p3)
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")

	relay(cur, router, p1)
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", client)).IBCDenom()
	println("impl:", transfer.ImplVersion(), "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob),
		"| receipt:", len(core.PacketReceipt(client, 1)) > 0, "| ack:", len(core.PacketAcknowledgement(client, 1)) > 0)

	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", client, string(collector), bridge, "", 10_000)))
	advance(7*24*time.Hour + time.Second) // the separate enrollment's delay, kept so the timeline stays
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), client, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "")))
	relay(cur, router, p2)
	e, _ := controlsView().Sweep(client, controls.PacketKey(client, 2))
	println("v1 receive swept:", e.Amount, e.Reason)
	relay(cur, router, p3)
	println("v1 receive refused, error ack:", string(core.PacketAcknowledgement(client, 3)) != string(core.PacketAcknowledgement(client, 2)))

	legacy := govern(cur, ibcgov.NewCreditRequest(cross(cur), client, controls.PacketKey(client, 1), voucher, string(bob), 900))
	execute(cur, legacy)
	println("credit of the v0 receive:", decided(legacy))
	booked := govern(cur, ibcgov.NewCreditRequest(cross(cur), client, controls.PacketKey(client, 2), voucher, string(bob), 50))
	execute(cur, booked)
	println("credit of the swept receive:", decided(booked))
	again := govern(cur, ibcgov.NewCreditRequest(cross(cur), client, controls.PacketKey(client, 2), voucher, string(bob), 50))
	execute(cur, again)
	println("credit again:", decided(again))
	errAcked := govern(cur, ibcgov.NewCreditRequest(cross(cur), client, controls.PacketKey(client, 3), voucher, string(bob), 50))
	execute(cur, errAcked)
	println("credit of the error-acknowledged receive:", decided(errAcked))
	c, _ := controlsView().Claim(client, controls.PacketKey(client, 2))
	_, legacyClaim := controlsView().Claim(client, controls.PacketKey(client, 1))
	println("claims:", c.Amount, c.By, "| v0 packet claimed:", legacyClaim, "| bob's vouchers:", transfer.VoucherBalanceOf(voucher, bob))
}

// Output:
// impl: v0 | bob's vouchers: 900 | receipt: true | ack: true
// v1 receive swept: 50 bridge realm
// v1 receive refused, error ack: true
// credit of the v0 receive: spent - spent: controls: packet ethereum-1/00000000000000000001 was not received under the route's controls (no sweep entry booked at its receipt): a receive from before the activation was paid already
// credit of the swept receive: applied - credit
// credit again: spent - spent: controls: packet ethereum-1/00000000000000000002 has a claim already
// credit of the error-acknowledged receive: spent - spent: packet ethereum-1/00000000000000000003 has no success acknowledgement: an error-acknowledged packet is refunded at its source
// claims: 50 vote | v0 packet claimed: false | bob's vouchers: 900
