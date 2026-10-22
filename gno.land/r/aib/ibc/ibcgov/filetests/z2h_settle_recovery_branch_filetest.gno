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

// settle builds a kind 12 for id and prints the refusal, or the epoch and
// seq it was dispatched as.
func settle(cur realm, id string) {
	if r := revive(func() { govern(cur, ibcgov.NewEthSettleRequest(cross(cur), id, "1:3:0")) }); r != nil {
		println("settle "+id+":", r)
		return
	}
	println("settle "+id+": dispatched as epoch", ibcgov.Epoch(), "seq", ibcgov.LastSeq(ibcgov.Epoch()))
}

// A router client governance named stays settleable whatever Ethereum's
// own history turns out to be: a kind 10 moves the route from client-0 to
// gnoland-b, and an emergency recovery is expected to move it from client-0
// to gnoland-x and on to gnoland-c. Ethereum executes the kind 10, then an
// emergency recovery of its own from gnoland-b to gnoland-c, which needs no
// expectation here; only gnoland-c's notice arrives, applied along the
// path through gnoland-x. No transition from gnoland-b to gnoland-c was
// ever recorded (and none can be now: Ethereum is past gnoland-b), the
// transfer route here moves from ethereum-1 straight to ethereum-3, yet
// gnoland-b's send records need settling: its kind 10 named it. An id
// governance never named stays out.
func main(cur realm) {
	route := client(cur, "client-0") // ethereum-1
	lb := client(cur, "gnoland-b")   // ethereum-2
	lx := client(cur, "gnoland-x")   // ethereum-3
	lc := client(cur, "gnoland-c")   // ethereum-4
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))

	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "client-0", "gnoland-b", 1, lb))
	execute(cur, ibcgov.LastDecision())
	execute(cur, govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-x", lx)))
	execute(cur, govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "gnoland-x", "gnoland-c", lc)))
	notice(cur, 3, "gnoland-c", lc) // two steps on: recorded as proven
	ibcgov.ApplyEpochNotice(cross(cur), 3, lc, "gnoland-x/"+lx+",gnoland-c/"+lc)
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())
	println("expect gnoland-b to gnoland-c now:", revive(func() { ibcgov.NewExpectRecoveryRequest(cross(cur), "gnoland-b", "gnoland-c", lc) }))
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, lc, 0)))
	println("the route here moved from", route, "to", lc)
	settle(cur, "gnoland-b")
	settle(cur, "gnoland-x")
	settle(cur, "client-0")
	settle(cur, "gnoland-z")
}

// Output:
// epoch 3 over ethereum-4
// expect gnoland-b to gnoland-c now: ibcgov: router client gnoland-b is not reachable from the governance epoch's client: Ethereum is past it
// the route here moved from ethereum-1 to ethereum-4
// settle gnoland-b: dispatched as epoch 3 seq 1
// settle gnoland-x: dispatched as epoch 3 seq 2
// settle client-0: dispatched as epoch 3 seq 3
// settle gnoland-z: ibcgov: gnoland-z is not an Ethereum router client of the route, current or retired: client-0, gnoland-b, gnoland-c, gnoland-x
