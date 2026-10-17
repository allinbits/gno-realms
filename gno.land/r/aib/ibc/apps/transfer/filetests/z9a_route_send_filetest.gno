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

// Sends of a gno-native token on an Ethereum route (ADR pr6375 §7.8, §7.13):
// the denom must be enabled, the amount within the send limits, the route fee
// paid on top, the receiver a valid, non-reserved, non-refused Ethereum
// address; a sends flag stops them. Every send writes its record.
func main(cur realm) {
	route := setupRoute(cur)
	println("before the denom:", revive(func() { send(cur, route, 100, 120, ethReceiver) }))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "4:"+string(watch))))
	govern(cur, ibcgov.NewRefuseRecipientsRequest(cross(cur), route, "0x1d95d544586eacb63b6154e9e45122b32ded11aa"))

	println("no fee:", revive(func() { send(cur, route, 100, 100, ethReceiver) }))
	println("below the minimum:", revive(func() { send(cur, route, 39, 59, ethReceiver) }))
	println("above the maximum:", revive(func() { send(cur, route, 25_001, 25_021, ethReceiver) }))
	println("zero address:", revive(func() { send(cur, route, 100, 120, "0x0000000000000000000000000000000000000000") }))
	println("to its Ethereum token:", revive(func() { send(cur, route, 100, 120, "0x0000000000000000000000000000000000C0FFEE") }))
	println("reserved:", revive(func() { send(cur, route, 100, 120, "0x000000000000000000000000000000000000ffff") }))
	println("malformed:", revive(func() { send(cur, route, 100, 120, "cosmos1abc") }))
	println("bad checksum:", revive(func() { send(cur, route, 100, 120, "0x5F67a5398d91087d1b37a8a43436196a7830867f") }))
	println("refused contract:", revive(func() { send(cur, route, 100, 120, "0x1D95D544586EACB63B6154E9E45122B32DED11AA") }))

	collectorBefore := ugnot(collector)
	seq := send(cur, route, 100, 120, ethReceiver)
	println("sent:", seq, "fee to the collector:", ugnot(collector)-collectorBefore)
	println(transfer.Render("total_escrow/ugnot"))
	rec, ok := controlsView().Send(route, controls.PacketKey(route, seq))
	println("record:", ok, rec.Amount, rec.Fee, rec.Sender == sender, rec.Receiver, rec.Outcome == "", rec.Packet.TimeoutTimestamp > 0)
	println("record commitment is the core's:", string(rec.Commitment) == string(core.PacketCommitment(route, seq)))
	println(transfer.Render("routes/" + route + "/sends"))

	// A sends flag stops gno-native sends at once.
	testing.SetRealm(testing.NewUserRealm(watch))
	ibcgov.SetFlag(cross(cur), route, ibcgov.FnSends, "")
	println("flagged:", revive(func() { send(cur, route, 100, 120, ethReceiver) }))
	println(transfer.Render("routes/" + route))
}

// Output:
// before the denom: denom ugnot is not enabled for sends on route ethereum-1
// no fee: send exactly 120ugnot: the amount plus the route fee of 20
// below the minimum: controls: 39 is below the minimum send of 40
// above the maximum: controls: 25001 is above the maximum send of 25000
// zero address: the receiver is the zero address
// to its Ethereum token: the receiver is the token itself
// reserved: the receiver is a reserved address (at or below 0xffff)
// malformed: the receiver is not an Ethereum address: want 0x and 40 hex digits
// bad checksum: the receiver is not an Ethereum address: mixed case that is not its EIP-55 checksum
// refused contract: the receiver is a contract of the bridge
// sent: 1 fee to the collector: 20
// {"denom":"ugnot","amount":100,"clients":[{"client":"ethereum-1","amount":100}]}
// record: true 100 20 true 0x5f67a5398d91087d1b37a8a43436196a7830867f true true
// record commitment is the core's: true
// {"entries":[{"key":"ethereum-1/00000000000000000001","packet":{"sequence":1,"source_client":"ethereum-1","destination_client":"client-0","timeout_timestamp":1236990694,"payloads":[{"source_port":"transfer","destination_port":"transfer","version":"ics20-1","encoding":"application/x-solidity-abi","value":"000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000000000000000000000000000000000000000000575676e6f740000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000028673177646a6b75657239776630343768366c746130343768366c746130343768366c647978356178000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a307835663637613533393864393130383764316233376138613433343336313936613738333038363766000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"}]},"commitment":"384e4719a608fdca78ca0088687060392acb9f346c4fd079e8e8911507e99883","sender":"g1wdjkuer9wf047h6lta047h6lta047h6ldyx5ax","receiver":"0x5f67a5398d91087d1b37a8a43436196a7830867f","denom":"ugnot","kind":"unescrow","amount":100,"fee":20,"sent_height":123,"sent_at":1236987094,"outcome":"","processed_height":0,"processed_at":0,"payment":"","refunded":0,"settlement":0,"reservation":0,"proven":0,"proven_at":0,"proven_by":"","proven_gen":0,"incident":""}],"next":""}
// flagged: sends are paused on route ethereum-1
// {"route":"ethereum-1","client":"ethereum-1","replaced":[],"enrolled":1235172691,"activated":123,"closed":false,"loss_closed":false,"fee_collector":"g1vdhkcmr9vd6x7ujlta047h6lta047h6lsp3m50","refused_recipients":["0x1d95d544586eacb63b6154e9e45122b32ded11aa"],"protected_recipients":["0x00000000000000000000000000000000000b0002 ics20","0x00000000000000000000000000000000000b0003 ibc admin","0x0000000000000000000000000000000000c0ffee voucher token","0x1d95d544586eacb63b6154e9e45122b32ded11aa router"],"unrecovered":0,"unresolved":0,"denoms":[{"denom":"ugnot","kind":"unescrow","cap_floor":10000,"launch_cap_floor":10000,"supply_cap":0,"fee":20,"fee_floor":2,"send_max":25000,"send_min":40,"refund_cap":10000,"remote":"0x0000000000000000000000000000000000c0ffee","meter":{"level":0,"at":1236382293,"epoch":0},"refund_meter":{"level":0,"at":1236382293},"waiting":0,"queued_refunds":0,"totals":{"credited":0,"owed":0,"withheld":0,"swept":0,"paid":0,"fees":0,"sweep_paid":0,"outstanding":0,"returning":0,"parked":0,"in_flight":100,"sent":100,"send_fees":20,"refunded":0,"queued_refunds":0,"lost":0,"recapitalized":0,"reduced":0,"accepted":0,"unrecovered":0,"unresolved":0}}]}
