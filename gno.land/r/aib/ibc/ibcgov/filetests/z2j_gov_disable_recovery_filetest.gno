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

// vector is gno-eth-ibc gov-vectors.json's kind14-disable-recovery
// (epoch 1, seq 18): the 14-byte header, then abi.encode(string clientId =
// "client-0"). This realm dispatches it at seq 1, so the kind and params
// are compared past the header's epoch and seq.
const vector = "010000000100000000000000120e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000008636c69656e742d30000000000000000000000000000000000000000000000000"

// Kind 14 (ADR pr6375 §5.4, §7.12): the permanent disable of Ethereum's
// emergency recovery. Its envelope is byte for byte the contract's vector;
// it names the route's current router client only (currentRouterClient),
// which an epoch switch moves.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	local := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), local, [][]byte{{}}, "gnoland-2")
	println("before the binding:", revive(func() { govern(cur, ibcgov.NewEthDisableRecoveryRequest(cross(cur), "client-0")) }))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(ibcgov.Governor()), "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003")))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), client)))

	d, _ := ibcgov.Decision(govern(cur, ibcgov.NewEthDisableRecoveryRequest(cross(cur), "client-0")))
	println("dispatched:", d.Note)
	body := hex.EncodeToString(ibcgov.DispatchBody(1, 1))
	println("header:", body[:28])
	println("kind and params match:", body[26:] == vector[26:])
	_, _, kind, _, _ := ibcgov.ParseEnvelope(ibcgov.DispatchBody(1, 1))
	println("kind", kind)

	println("not a router client id:", revive(func() { govern(cur, ibcgov.NewEthDisableRecoveryRequest(cross(cur), "abc")) }))
	println("another router client:", revive(func() { govern(cur, ibcgov.NewEthDisableRecoveryRequest(cross(cur), "gnoland-2")) }))
	println("this chain's client:", revive(func() { govern(cur, ibcgov.NewEthDisableRecoveryRequest(cross(cur), client)) }))

	// An epoch switch moves the router client it names: after IBCAdmin's
	// notice moves the epoch to gnoland-2, the old client is refused.
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "client-0", "gnoland-2", 1, local))
	expect := ibcgov.LastDecision()
	execute(cur, expect)
	np := types.Payload{SourcePort: ibcgov.GovDestPort, DestinationPort: ibcgov.GovPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: ibcgov.EpochNotice(2, "gnoland-2")}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	app.OnRecvPacket(cross(cur), "gnoland-2", local, 1, np)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("epoch", ibcgov.Epoch())
	println("the old client:", revive(func() { govern(cur, ibcgov.NewEthDisableRecoveryRequest(cross(cur), "client-0")) }))
	d, _ = ibcgov.Decision(govern(cur, ibcgov.NewEthDisableRecoveryRequest(cross(cur), "gnoland-2")))
	println("the new client:", d.Note)
}

// Output:
// before the binding: ibcgov: the governance channel is not bound
// dispatched: dispatched as epoch 1 seq 1
// header: 010000000100000000000000010e
// kind and params match: true
// kind 14
// not a router client id: ibcgov: not an Ethereum router client id: abc
// another router client: ibcgov: gnoland-2 is not the Ethereum router's current client of the route, client-0
// this chain's client: ibcgov: ethereum-1 is not the Ethereum router's current client of the route, client-0; ethereum-1 is this chain's client, paired with client-0
// epoch 2
// the old client: ibcgov: client-0 is not the Ethereum router's current client of the route, gnoland-2
// the new client: dispatched as epoch 2 seq 1
