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
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

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

func client(cur realm, counterparty string) string {
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, counterparty)
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

// replace dispatches the kind 10 from the router client old to next over
// the gno client local and applies its expectation.
func replace(cur realm, old, next, local string) {
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), old, next, 1, local))
	execute(cur, ibcgov.LastDecision())
}

// settle builds a kind 12 for id and prints the refusal, or the epoch and
// seq it was dispatched as.
func settle(cur realm, id string) {
	if r := revive(func() { govern(cur, ibcgov.NewEthSettleRequest(cross(cur), id, "1:3:0")) }); r != nil {
		println("settle "+id+":", r)
		return
	}
	println("settle "+id+": dispatched as epoch", ibcgov.Epoch(), "seq", ibcgov.LastSeq(ibcgov.Epoch()))
}

// A settlement (kind 12) names a router client Ethereum retired, which the
// transfer route's replacements here may never have had: Ethereum moves the
// route from client-0 to gnoland-b, then to gnoland-c, each notice moving
// the epoch here, while the route here moves from ethereum-1 straight to
// ethereum-3. gnoland-b is no client of the route here, current or
// retired, yet its send records may still need settling (returning
// vouchers stayed sendable while Ethereum's route was closed), so the
// router clients the governance epoch ran over are kept, and a catch-up
// adds every router client of the expected graph on a path to the
// notice's client, not only the path whoever applied it named.
func main(cur realm) {
	route := client(cur, "client-0") // ethereum-1
	lb := client(cur, "gnoland-b")   // ethereum-2
	lc := client(cur, "gnoland-c")   // ethereum-3
	ld := client(cur, "gnoland-d")   // ethereum-4
	lx := client(cur, "gnoland-x")   // ethereum-5
	le := client(cur, "gnoland-e")   // ethereum-6
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))

	replace(cur, "client-0", "gnoland-b", lb)
	notice(cur, 2, "gnoland-b", lb)
	replace(cur, "gnoland-b", "gnoland-c", lc)
	notice(cur, 3, "gnoland-c", lc)
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, lc, 0)))
	println("the route here moved from", route, "to", lc)
	settle(cur, "gnoland-b")
	settle(cur, "client-0")
	settle(cur, "gnoland-d")

	// A catch-up with two approved paths: Ethereum moves on to gnoland-e
	// through gnoland-d (kind 10s gnoland-c to gnoland-d, gnoland-d to
	// gnoland-e), the competing kind 10s through gnoland-x approved too;
	// only gnoland-e's notice arrives, and whoever applies it names the
	// path through gnoland-x. Every router client on an approved path from
	// gnoland-c to gnoland-e enters the history, gnoland-d included, which
	// Ethereum retired on its way; an id governance never approved stays
	// out.
	replace(cur, "gnoland-c", "gnoland-d", ld)
	replace(cur, "gnoland-c", "gnoland-x", lx)
	replace(cur, "gnoland-d", "gnoland-e", le)
	replace(cur, "gnoland-x", "gnoland-e", le)
	notice(cur, 5, "gnoland-e", le) // two steps on: recorded as proven
	ibcgov.ApplyEpochNotice(cross(cur), 5, le, "gnoland-x/"+lx+",gnoland-e/"+le)
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())
	settle(cur, "gnoland-d")
	settle(cur, "gnoland-x")
	settle(cur, "gnoland-b")
	settle(cur, "gnoland-z")
}

// Output:
// epoch 3 over ethereum-3
// the route here moved from ethereum-1 to ethereum-3
// settle gnoland-b: dispatched as epoch 3 seq 1
// settle client-0: dispatched as epoch 3 seq 2
// settle gnoland-d: ibcgov: gnoland-d is not an Ethereum router client of the route, current or retired: client-0, gnoland-b, gnoland-c
// epoch 5 over ethereum-6
// settle gnoland-d: dispatched as epoch 5 seq 1
// settle gnoland-x: dispatched as epoch 5 seq 2
// settle gnoland-b: dispatched as epoch 5 seq 3
// settle gnoland-z: ibcgov: gnoland-z is not an Ethereum router client of the route, current or retired: client-0, gnoland-b, gnoland-c, gnoland-d, gnoland-e, gnoland-x
