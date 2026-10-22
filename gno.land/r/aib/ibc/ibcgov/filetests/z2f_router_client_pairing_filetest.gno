// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const (
	bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"
	a1     = "0x1111111111111111111111111111111111111111"
	hash   = "abababababababababababababababababababababababababababababababab"
)

var collector = testutils.TestAddress("collector")

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

// try builds and governs a request, printing the refusal or the seq it was
// dispatched as.
func try(cur realm, name string, build func() ibcgov.Request) {
	if r := revive(func() { govern(cur, build()) }); r != nil {
		println(name+":", r)
		return
	}
	println(name+": dispatched as epoch", ibcgov.Epoch(), "seq", ibcgov.LastSeq(ibcgov.Epoch()))
}

func client(cur realm, counterparty string) string {
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	if counterparty != "" {
		core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, counterparty)
	}
	return id
}

// notice delivers IBCAdmin's epoch notice of epoch e over the gno client
// local, from the router client it names, as the core does once verified.
func notice(cur realm, e uint32, named, local string) {
	payload := types.Payload{SourcePort: ibcgov.GovDestPort, DestinationPort: ibcgov.GovPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: ibcgov.EpochNotice(e, named)}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	app.OnRecvPacket(cross(cur), named, local, 1, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// An Ethereum-bound decision names the router's client id, never this
// chain's, which the router's grammar admits all the same: on a test network
// a kind 4 built for the gno client ethereum-1 was recorded by Ethereum under
// a route key nothing uses, and the route stayed unconfigured. This chain
// knows the pairing (the counterparty the core registered for each of its
// Ethereum clients), so every builder checks its id against it: a kind
// naming the route takes the router's current client, the epoch client's
// counterparty; a settlement (kind 12) any router client of the route's
// lineage; a verifier migration (kind 6 op 2) any router client paired with
// a governed client; a kind 6 op 1 the custom id its gno client is paired
// with; a kind 10 or a recovery expectation an old client the epoch reaches.
// A client of this chain is refused with the id that was meant, and the
// check runs again when the decision is recorded.
func main(cur realm) {
	route := client(cur, "client-0")  // ethereum-1, the route's client
	local := client(cur, "gnoland-2") // ethereum-2, paired with the kind 10's new client
	bare := client(cur, "")           // ethereum-3, no counterparty yet
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector), bridge)))
	println("before the binding:", revive(func() { ibcgov.NewEthLimitsRequest(cross(cur), "client-0", a1, "1", "1", "1", "0", "0") }))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "paired with", core.CounterpartyClientID(ibcgov.EpochClient()))

	// Every kind naming the route takes its router client only: this
	// chain's client of it, a paired client that is not the route's, a
	// client with no counterparty and an unknown id are refused.
	for _, id := range []string{route, local, bare, "gnoland-9", "client-0"} {
		try(cur, "unpause "+id, func() ibcgov.Request { return ibcgov.NewEthUnpauseRequest(cross(cur), 1, id) })
		try(cur, "limits "+id, func() ibcgov.Request { return ibcgov.NewEthLimitsRequest(cross(cur), id, a1, "1", "1", "1", "0", "0") })
		try(cur, "voucher "+id, func() ibcgov.Request { return ibcgov.NewEthVoucherRequest(cross(cur), id, "ugnot", a1, hash) })
		try(cur, "settings "+id, func() ibcgov.Request { return ibcgov.NewEthRouteSettingsRequest(cross(cur), id, 3600) })
		try(cur, "reopen "+id, func() ibcgov.Request { return ibcgov.NewEthReopenRequest(cross(cur), id) })
		try(cur, "settle "+id, func() ibcgov.Request { return ibcgov.NewEthSettleRequest(cross(cur), id, "1:3:0") })
		try(cur, "migrate "+id, func() ibcgov.Request { return ibcgov.NewEthClientRequest(cross(cur), 2, id, "", "6d61696e", a1, hash) })
	}

	// Kind 6 op 1 adds the custom id the gno client it tracks is paired with.
	add := func(id, tracks string) func() ibcgov.Request {
		return func() ibcgov.Request {
			return ibcgov.NewEthClientRequest(cross(cur), 1, id, tracks, "6d61696e", a1, hash)
		}
	}
	try(cur, "add gnoland-2 tracking "+local, add("gnoland-2", local))
	try(cur, "add gnoland-9 tracking "+local, add("gnoland-9", local))
	try(cur, "add "+local+" tracking "+local, add(local, local))
	try(cur, "add gnoland-2 tracking "+route, add("gnoland-2", route))
	try(cur, "add gnoland-3 tracking "+bare, add("gnoland-3", bare))
	try(cur, "add gnoland-2 tracking gnoland-2", add("gnoland-2", "gnoland-2"))

	// A kind 10 and a recovery expectation name the old client in the
	// router's ids; a verifier migration names a router client governance
	// named before, the kind 6 op 1 that added gnoland-2 above included.
	try(cur, "replace "+route, func() ibcgov.Request {
		return ibcgov.NewEthRouteReplacementRequest(cross(cur), route, "gnoland-2", 1, local)
	})
	try(cur, "expect recovery from "+route, func() ibcgov.Request { return ibcgov.NewExpectRecoveryRequest(cross(cur), route, "gnoland-2", local) })
	try(cur, "migrate gnoland-2 after its kind 6 op 1", func() ibcgov.Request {
		return ibcgov.NewEthClientRequest(cross(cur), 2, "gnoland-2", "", "6d61696e", a1, hash)
	})
	try(cur, "replace client-0", func() ibcgov.Request {
		return ibcgov.NewEthRouteReplacementRequest(cross(cur), "client-0", "gnoland-2", 1, local)
	})
	expect := ibcgov.LastDecision()

	// The epoch moves to gnoland-2 over ethereum-2: a request built before
	// the switch is spent when it is recorded after it, the route's router
	// client is gnoland-2 from now on, and a settlement names either router
	// client the epoch ran over (Ethereum alone can tell which it retired).
	stale := ibcgov.NewEthLimitsRequest(cross(cur), "client-0", a1, "1", "1", "1", "0", "0")
	execute(cur, expect)
	notice(cur, 2, "gnoland-2", local)
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient(), "paired with", core.CounterpartyClientID(ibcgov.EpochClient()))
	d, _ := ibcgov.Decision(govern(cur, stale))
	println("the limits request built before the switch:", d.State(), "-", d.Note)
	for _, id := range []string{"client-0", "gnoland-2"} {
		try(cur, "limits "+id, func() ibcgov.Request { return ibcgov.NewEthLimitsRequest(cross(cur), id, a1, "1", "1", "1", "0", "0") })
		try(cur, "reopen "+id, func() ibcgov.Request { return ibcgov.NewEthReopenRequest(cross(cur), id) })
		try(cur, "settle "+id, func() ibcgov.Request { return ibcgov.NewEthSettleRequest(cross(cur), id, "1:3:0") })
	}

	// The route's replacement here moves it onto ethereum-2: both router
	// clients stay settleable.
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, local, 0)))
	for _, id := range []string{"client-0", "gnoland-2"} {
		try(cur, "settle "+id+" after the replacement", func() ibcgov.Request { return ibcgov.NewEthSettleRequest(cross(cur), id, "1:3:0") })
	}
}

// Output:
// before the binding: ibcgov: the governance channel is not bound
// epoch 1 over ethereum-1 paired with client-0
// unpause ethereum-1: ibcgov: ethereum-1 is not the Ethereum router's current client of the route, client-0; ethereum-1 is this chain's client, paired with client-0
// limits ethereum-1: ibcgov: ethereum-1 is not the Ethereum router's current client of the route, client-0; ethereum-1 is this chain's client, paired with client-0
// voucher ethereum-1: ibcgov: ethereum-1 is not the Ethereum router's current client of the route, client-0; ethereum-1 is this chain's client, paired with client-0
// settings ethereum-1: ibcgov: ethereum-1 is not the Ethereum router's current client of the route, client-0; ethereum-1 is this chain's client, paired with client-0
// reopen ethereum-1: ibcgov: ethereum-1 is not the Ethereum router's current client of the route, client-0; ethereum-1 is this chain's client, paired with client-0
// settle ethereum-1: ibcgov: ethereum-1 is not an Ethereum router client of the route, current or retired: client-0; ethereum-1 is this chain's client, paired with client-0
// migrate ethereum-1: ibcgov: ethereum-1 is not an Ethereum router client this realm pairs with a client of this chain: client-0; ethereum-1 is this chain's client, paired with client-0
// unpause ethereum-2: ibcgov: ethereum-2 is not the Ethereum router's current client of the route, client-0; ethereum-2 is this chain's client, paired with gnoland-2
// limits ethereum-2: ibcgov: ethereum-2 is not the Ethereum router's current client of the route, client-0; ethereum-2 is this chain's client, paired with gnoland-2
// voucher ethereum-2: ibcgov: ethereum-2 is not the Ethereum router's current client of the route, client-0; ethereum-2 is this chain's client, paired with gnoland-2
// settings ethereum-2: ibcgov: ethereum-2 is not the Ethereum router's current client of the route, client-0; ethereum-2 is this chain's client, paired with gnoland-2
// reopen ethereum-2: ibcgov: ethereum-2 is not the Ethereum router's current client of the route, client-0; ethereum-2 is this chain's client, paired with gnoland-2
// settle ethereum-2: ibcgov: ethereum-2 is not an Ethereum router client of the route, current or retired: client-0; ethereum-2 is this chain's client, paired with gnoland-2
// migrate ethereum-2: ibcgov: ethereum-2 is not an Ethereum router client this realm pairs with a client of this chain: client-0; ethereum-2 is this chain's client, paired with gnoland-2
// unpause ethereum-3: ibcgov: ethereum-3 is not the Ethereum router's current client of the route, client-0; ethereum-3 is this chain's client, with no counterparty registered
// limits ethereum-3: ibcgov: ethereum-3 is not the Ethereum router's current client of the route, client-0; ethereum-3 is this chain's client, with no counterparty registered
// voucher ethereum-3: ibcgov: ethereum-3 is not the Ethereum router's current client of the route, client-0; ethereum-3 is this chain's client, with no counterparty registered
// settings ethereum-3: ibcgov: ethereum-3 is not the Ethereum router's current client of the route, client-0; ethereum-3 is this chain's client, with no counterparty registered
// reopen ethereum-3: ibcgov: ethereum-3 is not the Ethereum router's current client of the route, client-0; ethereum-3 is this chain's client, with no counterparty registered
// settle ethereum-3: ibcgov: ethereum-3 is not an Ethereum router client of the route, current or retired: client-0; ethereum-3 is this chain's client, with no counterparty registered
// migrate ethereum-3: ibcgov: ethereum-3 is not an Ethereum router client this realm pairs with a client of this chain: client-0; ethereum-3 is this chain's client, with no counterparty registered
// unpause gnoland-9: ibcgov: gnoland-9 is not the Ethereum router's current client of the route, client-0
// limits gnoland-9: ibcgov: gnoland-9 is not the Ethereum router's current client of the route, client-0
// voucher gnoland-9: ibcgov: gnoland-9 is not the Ethereum router's current client of the route, client-0
// settings gnoland-9: ibcgov: gnoland-9 is not the Ethereum router's current client of the route, client-0
// reopen gnoland-9: ibcgov: gnoland-9 is not the Ethereum router's current client of the route, client-0
// settle gnoland-9: ibcgov: gnoland-9 is not an Ethereum router client of the route, current or retired: client-0
// migrate gnoland-9: ibcgov: gnoland-9 is not an Ethereum router client this realm pairs with a client of this chain: client-0
// unpause client-0: dispatched as epoch 1 seq 1
// limits client-0: dispatched as epoch 1 seq 2
// voucher client-0: dispatched as epoch 1 seq 3
// settings client-0: dispatched as epoch 1 seq 4
// reopen client-0: dispatched as epoch 1 seq 5
// settle client-0: dispatched as epoch 1 seq 6
// migrate client-0: dispatched as epoch 1 seq 7
// add gnoland-2 tracking ethereum-2: dispatched as epoch 1 seq 8
// add gnoland-9 tracking ethereum-2: ibcgov: the gno client ethereum-2 is paired with gnoland-2, not gnoland-9
// add ethereum-2 tracking ethereum-2: ibcgov: the gno client ethereum-2 is paired with gnoland-2, not ethereum-2
// add gnoland-2 tracking ethereum-1: ibcgov: the gno client ethereum-1 is paired with client-0, not gnoland-2
// add gnoland-3 tracking ethereum-3: ibcgov: the gno client ethereum-3 is paired with no router client yet, not gnoland-3
// add gnoland-2 tracking gnoland-2: ibcgov: the counterparty gnoland-2 is not a gno client
// replace ethereum-1: ibcgov: router client ethereum-1 is not reachable from the governance epoch's client: Ethereum is past it; ethereum-1 is this chain's client, paired with client-0
// expect recovery from ethereum-1: ibcgov: router client ethereum-1 is not reachable from the governance epoch's client: Ethereum is past it; ethereum-1 is this chain's client, paired with client-0
// migrate gnoland-2 after its kind 6 op 1: dispatched as epoch 1 seq 9
// replace client-0: dispatched as epoch 1 seq 10
// epoch 2 over ethereum-2 paired with gnoland-2
// the limits request built before the switch: spent - spent: client-0 is not the Ethereum router's current client of the route, gnoland-2
// limits client-0: ibcgov: client-0 is not the Ethereum router's current client of the route, gnoland-2
// reopen client-0: ibcgov: client-0 is not the Ethereum router's current client of the route, gnoland-2
// settle client-0: dispatched as epoch 2 seq 1
// limits gnoland-2: dispatched as epoch 2 seq 2
// reopen gnoland-2: dispatched as epoch 2 seq 3
// settle gnoland-2: dispatched as epoch 2 seq 4
// settle client-0 after the replacement: dispatched as epoch 2 seq 5
// settle gnoland-2 after the replacement: dispatched as epoch 2 seq 6
