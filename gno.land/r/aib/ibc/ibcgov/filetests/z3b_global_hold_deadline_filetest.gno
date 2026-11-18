// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is each route's router, ICS20 transfer and IBCAdmin.
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	a0        = testutils.TestAddress("a-guardian-0")
	a1        = testutils.TestAddress("a-guardian-1")
	b0        = testutils.TestAddress("b-guardian-0")
	both      = testutils.TestAddress("guardian-of-both")
)

func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// chainClient creates an Ethereum client of chain id, its counterparty the
// router client counterparty.
func chainClient(cur realm, id uint64, counterparty string) string {
	cs := ethtesting.ClientState()
	cs.ChainID = id
	c := core.CreateClient(cross(cur), cs, ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), c, [][]byte{{}}, counterparty)
	return c
}

func flagAs(cur realm, who address, route, target, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.SetFlag(cross(cur), route, target, fn, "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func clearAs(cur realm, who address, route, target, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.ClearFlag(cross(cur), route, target, fn)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// The global hold (ADR 0007 §6): any route's hold defers a global decision,
// to day 21 of the global hold that first deferred it at most: holds chained
// across routes never push it further. A global unpause is deferred too,
// never spent; a route's unpause is still spent by its route's hold.
func main(cur realm) {
	a := chainClient(cur, 1, "client-0")
	b := chainClient(cur, 2, "client-0")
	c := chainClient(cur, 3, "client-0") // made before a relayer is listed
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), a, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), b, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), a, "0:"+string(a0)+",1:"+string(a1))))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), b, "0:"+string(b0)+",1:"+string(both))))
	govern(cur, ibcgov.NewCorePauseRequest(cross(cur)))

	// A holds; a global decision comes due under it.
	global := govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("relayer"))))
	flagAs(cur, a0, a, a, ibcgov.FnSends)
	flagAs(cur, a1, a, a, ibcgov.FnSends)
	since := ibcgov.GlobalHoldSince()
	println("global hold since A's:", since == ibcgov.HoldSince(a))
	// A global unpause is deferred, not spent, and so is a later one.
	unpause := govern(cur, ibcgov.NewCoreUnpauseRequest(cross(cur)))
	println("core unpause under A's hold:", decided(unpause), "| core paused:", core.Paused())
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), global)
	println("global decision, first deferral:", decided(global))

	// Day 20: B's guardians start a hold; day 21: A's seats are cleared. The
	// global hold never had a gap, and the deadline does not move.
	advance(time.Duration(since+20*86400-testing.GetContext().Time.Unix()) * time.Second)
	flagAs(cur, b0, b, b, ibcgov.FnCredits)
	flagAs(cur, both, b, b, ibcgov.FnCredits)
	clearAs(cur, a0, a, a, ibcgov.FnSends)
	clearAs(cur, a1, a, a, ibcgov.FnSends)
	println("day 20: A held", ibcgov.Held(a), "B held", ibcgov.Held(b), "| global since unchanged:", ibcgov.GlobalHoldSince() == since)
	advance(time.Duration(since+21*86400-1-testing.GetContext().Time.Unix()) * time.Second)
	println("a second before day 21:", revive(func() { ibcgov.Execute(cross(cur), global) }))
	println("the unpause before day 21:", revive(func() { ibcgov.Execute(cross(cur), unpause) }))
	advance(time.Duration(since+21*86400-testing.GetContext().Time.Unix()) * time.Second)
	ibcgov.Execute(cross(cur), global)
	ibcgov.Execute(cross(cur), unpause)
	println("day 21, B still holding:", ibcgov.Held(b), "| global:", decided(global), "| unpause:", decided(unpause), "| core paused:", core.Paused())

	// A route unpause under its route's hold is still spent; one of another
	// route is not.
	unB := govern(cur, ibcgov.NewUnpauseRouteRequest(cross(cur), b, b, "credits"))
	println("B's unpause under B's hold:", decided(unB))
	flagAs(cur, a0, a, a, ibcgov.FnRefunds)
	unA := govern(cur, ibcgov.NewUnpauseRouteRequest(cross(cur), a, a, "refunds"))
	println("A's unpause under B's hold:", decided(unA))

	// A new global hold after a gap anchors anew.
	clearAs(cur, b0, b, b, ibcgov.FnCredits)
	clearAs(cur, both, b, b, ibcgov.FnCredits)
	advance(24*time.Hour + time.Second)
	println("no hold:", ibcgov.AnyHeld(), ibcgov.GlobalHoldSince())
	// A global decision under overlapping lingers: B's hold ends and lingers,
	// A's starts and ends within it and lingers later; a third route enrols
	// meanwhile. The decision waits exactly for the later linger to end.
	later := govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("relayer-2"))))
	enrolC := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), c, string(collector), bridge))
	advance(7*24*time.Hour + time.Second)
	flagAs(cur, b0, b, b, ibcgov.FnSends)
	flagAs(cur, both, b, b, ibcgov.FnSends)
	println("a new global hold:", ibcgov.GlobalHoldSince() == testing.GetContext().Time.Unix())
	ibcgov.Execute(cross(cur), later) // anchored
	advance(time.Hour)
	clearAs(cur, b0, b, b, ibcgov.FnSends)
	clearAs(cur, both, b, b, ibcgov.FnSends)
	advance(time.Hour)
	flagAs(cur, a0, a, a, ibcgov.FnCredits)
	flagAs(cur, a1, a, a, ibcgov.FnCredits)
	advance(time.Hour)
	clearAs(cur, a0, a, a, ibcgov.FnCredits)
	clearAs(cur, a1, a, a, ibcgov.FnCredits)
	end := testing.GetContext().Time.Unix() + 86400 // A's linger ends after B's
	ibcgov.Execute(cross(cur), enrolC)
	println("a third route enrolled during the lingers:", decided(enrolC), "| any held:", ibcgov.AnyHeld())
	advance(time.Duration(end-1-testing.GetContext().Time.Unix()) * time.Second)
	println("a second before the later linger ends:", revive(func() { ibcgov.Execute(cross(cur), later) }))
	advance(time.Second)
	ibcgov.Execute(cross(cur), later)
	println("when it ends:", decided(later), "| any held:", ibcgov.AnyHeld())
}

// Output:
// global hold since A's: true
// core unpause under A's hold: pending -  | core paused: true
// global decision, first deferral: pending - queued 7 days
// day 20: A held true B held true | global since unchanged: true
// a second before day 21: ibcgov: decision 6 is deferred: a guardian hold first deferred it on 1236987094, until 1238801494
// the unpause before day 21: ibcgov: decision 7 is deferred: a guardian hold first deferred it on 1236987094, until 1238801494
// day 21, B still holding: true | global: applied - core add relayer | unpause: applied - core unpaused | core paused: false
// B's unpause under B's hold: spent - spent: route ethereum-2's guardian hold stands, which spends its unpauses
// A's unpause under B's hold: applied - cleared 1 flags of route ethereum-1
// no hold: false 0
// a new global hold: true
// a third route enrolled during the lingers: applied - enroll | any held: true
// a second before the later linger ends: ibcgov: decision 10 is deferred: a guardian hold first deferred it on 1239492696, until 1241307096
// when it ends: applied - core add relayer | any held: false
