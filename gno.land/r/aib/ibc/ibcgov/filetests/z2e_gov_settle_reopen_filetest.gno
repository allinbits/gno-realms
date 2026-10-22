// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
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

// vectors are the envelopes of kinds 12 and 13 at epoch 1, seqs 1 and 2,
// computed independently of this realm: the 14-byte header followed by viem
// 2.56.3's encodeAbiParameters of (string clientId, (uint64 sequence, uint8
// action, uint256 amount)[] items) and of (string clientId) (ADR pr6375 §5.4
// table), and matching gno-eth-ibc gov-vectors.json at 8dad3f9 (z2c). The
// reopen names gnoland-2, the kind 10's new client, which this realm sends
// only once the epoch moved there: its kind and params are compared past
// the header's epoch and seq.
var vectors = map[uint64]string{
	1: "010000000100000000000000010c000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000008636c69656e742d3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000005d21dba000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000018ee90ff6c373e0ee4e3f0ad2",
	2: "010000000100000000000000020d00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000009676e6f6c616e642d320000000000000000000000000000000000000000000000",
}

// Kinds 12 (settle) and 13 (reopen), the Ethereum side of a route's recovery
// (ADR pr6375 §5.4, §7.12, Codex review #4): typed, bounded builders whose
// envelopes are byte for byte the expected encoding, all four settlement
// actions included; then the recovery's order on the channel: the route
// replacement, its settlement and, once IBCAdmin's epoch notice moved the
// epoch to the new client, its reopening.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	local := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), local, [][]byte{{}}, "gnoland-2")
	// The governance channel rides a route: enroll the client first.
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(ibcgov.Governor()), "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003")))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), client)))

	govern(cur, ibcgov.NewEthSettleRequest(cross(cur), "client-0", "1:1:25000000000,2:2:0,3:3:0,4:4:123456789012345678901234567890"))
	println("seq 1 matches:", hex.EncodeToString(ibcgov.DispatchBody(1, 1)) == vectors[1])

	for _, items := range []string{
		"1:4:0",       // a forged refund paid nothing
		"1:2:5",       // a rejection with an amount
		"1:3:1",       // a delivery with an amount
		"1:5:0",       // a forged receive of nothing
		"1:6:0",       // no such action
		"0:3:0",       // no sequence
		"1:3:0,1:2:0", // a sequence twice
		"1:1:x",       // not a number
		"1:3:0,2:3:0,3:3:0,4:3:0,5:3:0,6:3:0,7:3:0,8:3:0,9:3:0", // more than 8
	} {
		println(items+":", revive(func() { govern(cur, ibcgov.NewEthSettleRequest(cross(cur), "client-0", items)) }))
	}
	println("settle of no router client:", revive(func() { govern(cur, ibcgov.NewEthSettleRequest(cross(cur), "abc", "1:3:0")) }))
	println("reopen of no router client:", revive(func() { govern(cur, ibcgov.NewEthReopenRequest(cross(cur), "channel-1")) }))

	// Eight items with the longest client id still fit the envelope: a
	// settlement names a router client of the route's lineage, here the one
	// paired with the client a replacement moved the route onto.
	long := "gnoland-" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456"
	longClient := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), longClient, [][]byte{{}}, long)
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), client, longClient, 0)))
	eight := "1:1:340282366920938463463374607431768211455,2:4:340282366920938463463374607431768211455,3:3:0,4:3:0,5:3:0,6:3:0,7:3:0,8:2:0"
	govern(cur, ibcgov.NewEthSettleRequest(cross(cur), long, eight))
	println("eight items:", len(ibcgov.DispatchBody(1, 2)), "bytes")

	// The recovery's order on the channel: the route replacement (kind 10)
	// in the epoch it retires, then, once IBCAdmin's epoch notice moved the
	// epoch to the new client, the retired client's settlement and the
	// reopening, in the new epoch. A settlement dispatched before the switch
	// is abandoned by it: Ethereum refuses to settle a client it has not
	// retired, and the switch abandons epoch 1's pending decisions, never
	// sent again. A reopen before names a router client the route is not
	// on.
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "client-0", "gnoland-2", 1, local))
	expect := ibcgov.LastDecision()
	_, _, kind, _, _ := ibcgov.ParseEnvelope(ibcgov.DispatchBody(1, 3))
	println("seq 3 kind", kind)
	govern(cur, ibcgov.NewEthSettleRequest(cross(cur), "client-0", "1:3:0")) // epoch 1 seq 4: abandoned below
	println("reopen before the switch:", revive(func() { govern(cur, ibcgov.NewEthReopenRequest(cross(cur), "gnoland-2")) }))
	execute(cur, expect)
	np := types.Payload{SourcePort: ibcgov.GovDestPort, DestinationPort: ibcgov.GovPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: ibcgov.EpochNotice(2, "gnoland-2")}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	app.OnRecvPacket(cross(cur), "gnoland-2", local, 1, np)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())
	println("the settlement of epoch 1:", revive(func() { ibcgov.Redispatch(cross(cur), 1, 4) }))
	d, _ := ibcgov.Decision(govern(cur, ibcgov.NewEthSettleRequest(cross(cur), "client-0", "1:3:0")))
	println("settle in the new epoch:", d.Note)
	d, _ = ibcgov.Decision(govern(cur, ibcgov.NewEthReopenRequest(cross(cur), "gnoland-2")))
	println("reopen in the new epoch:", d.Note)
	println("seq 2's kind and params match:", hex.EncodeToString(ibcgov.DispatchBody(2, 2))[26:] == vectors[2][26:])

	// A genuine refund paid in full settles with a zero payment (Codex round
	// 3 #5).
	govern(cur, ibcgov.NewEthSettleRequest(cross(cur), "client-0", "7:1:0"))
	println("zero payment dispatched:", ibcgov.LastSeq(2))

	// A packet the core would refuse to send spends its decision, binding no
	// number (Codex round 2 #3).
	govern(cur, ibcgov.NewCorePauseRequest(cross(cur)))
	d, _ = ibcgov.Decision(govern(cur, ibcgov.NewEthReopenRequest(cross(cur), "gnoland-2")))
	println("while the core is paused:", d.State(), "-", d.Note, "| last seq", ibcgov.LastSeq(2))
}

// Output:
// seq 1 matches: true
// 1:4:0: ibcgov: a forged refund or receive names its positive amount, a rejection or a delivery 0: 1:4:0
// 1:2:5: ibcgov: a forged refund or receive names its positive amount, a rejection or a delivery 0: 1:2:5
// 1:3:1: ibcgov: a forged refund or receive names its positive amount, a rejection or a delivery 0: 1:3:1
// 1:5:0: ibcgov: a forged refund or receive names its positive amount, a rejection or a delivery 0: 1:5:0
// 1:6:0: ibcgov: not a settlement item, or a sequence named twice in its direction: 1:6:0
// 0:3:0: ibcgov: not a settlement item, or a sequence named twice in its direction: 0:3:0
// 1:3:0,1:2:0: ibcgov: not a settlement item, or a sequence named twice in its direction: 1:2:0
// 1:1:x: ibcgov: amount: abi: not a decimal number
// 1:3:0,2:3:0,3:3:0,4:3:0,5:3:0,6:3:0,7:3:0,8:3:0,9:3:0: ibcgov: name 1 to 8 settlement items
// settle of no router client: ibcgov: not an Ethereum router client id: abc
// reopen of no router client: ibcgov: not an Ethereum router client id: channel-1
// eight items: 974 bytes
// seq 3 kind 10
// reopen before the switch: ibcgov: gnoland-2 is not the Ethereum router's current client of the route, client-0
// epoch 2 over ethereum-2
// the settlement of epoch 1: ibcgov: epoch 1 is past: its decisions are never sent again
// settle in the new epoch: dispatched as epoch 2 seq 1
// reopen in the new epoch: dispatched as epoch 2 seq 2
// seq 2's kind and params match: true
// zero payment dispatched: 3
// while the core is paused: spent - spent: the core is paused: no governance packet can be sent | last seq 3
