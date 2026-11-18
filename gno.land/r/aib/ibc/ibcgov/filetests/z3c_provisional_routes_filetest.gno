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

// Provisional route records (ADR 0007 §5): seats set for a router client no
// route uses yet create its record and reserve its chain; the enrolment of
// that client adopts the seats and flags, another client of the chain is
// refused. A drop needs vacant seats, no hold or linger, no flag entry and no
// other pending decision of the incarnation; a key used again is a new
// incarnation, and a request built for the old one is spent. Flags on a
// candidate fold only into their own route.
func main(cur realm) {
	// Seats before the enrolment: a provisional record.
	c := chainClient(cur, 3, "client-0")
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), c, "0:"+string(a0)+",1:"+string(a1))))
	println("provisional:", ibcgov.IsProvisionalRoute(c), "enrolled:", ibcgov.IsRoute(c), "incarnation", ibcgov.Incarnation(c))
	flagAs(cur, a0, c, c, ibcgov.FnCredits)
	println("flagged before enrolment:", ibcgov.Flagged(c, ibcgov.FnCredits))
	other := chainClient(cur, 3, "client-1")
	println("another client of the chain:", revive(func() {
		govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), other, string(collector), bridge))
	}))
	println("seats for another client of the chain:", revive(func() {
		govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), other, "0:"+string(b0)))
	}))
	enrol := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), c, string(collector), bridge))
	execute(cur, enrol)
	println("enrolled:", decided(enrol))
	println("adopted: seat 0", ibcgov.Seat(c, 0) == a0, "credits flagged", ibcgov.Flagged(c, ibcgov.FnCredits), "incarnation", ibcgov.Incarnation(c))
	println("drop an enrolled route:", revive(func() { govern(cur, ibcgov.NewDropRouteRequest(cross(cur), c)) }))

	// Dropping a provisional record.
	d := chainClient(cur, 4, "client-0")
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), d, "0:"+string(b0)+",1:"+string(both))))
	flagAs(cur, b0, d, d, ibcgov.FnSends)
	flagAs(cur, both, d, d, ibcgov.FnSends)
	println("a seat occupied:", revive(func() { govern(cur, ibcgov.NewDropRouteRequest(cross(cur), d)) }))
	vacate := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), d, "0:,1:"))
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), vacate) // under d's hold: anchored
	advance(14 * 24 * time.Hour)
	ibcgov.Execute(cross(cur), vacate)
	println("vacated on day 21:", decided(vacate), "| held:", ibcgov.Held(d))
	println("while it lingers:", revive(func() { govern(cur, ibcgov.NewDropRouteRequest(cross(cur), d)) }))
	advance(24*time.Hour + time.Second)
	println("stale flag entries:", revive(func() { govern(cur, ibcgov.NewDropRouteRequest(cross(cur), d)) }))
	println("pruned:", ibcgov.PruneFlags(cross(cur), d, 8))
	pending := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), d, "5:"+string(a1)))
	println("another decision pending:", revive(func() { govern(cur, ibcgov.NewDropRouteRequest(cross(cur), d)) }))
	govern(cur, ibcgov.NewCancelRequest(cross(cur), pending))
	// A drop valid when recorded is checked again when it executes: another
	// decision of the incarnation recorded meanwhile spends it.
	early := govern(cur, ibcgov.NewDropRouteRequest(cross(cur), d))
	pending = govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), d, "5:"+string(a1)))
	execute(cur, early)
	println("a drop executed with another decision pending:", decided(early), "| record:", ibcgov.IsProvisionalRoute(d))
	govern(cur, ibcgov.NewCancelRequest(cross(cur), pending))
	stale := ibcgov.NewSetSeatsRequest(cross(cur), d, "4:"+string(a0)) // built for incarnation 1
	drop := govern(cur, ibcgov.NewDropRouteRequest(cross(cur), d))
	execute(cur, drop)
	println("dropped:", decided(drop), "| record:", ibcgov.IsProvisionalRoute(d))
	// A request built for the dropped incarnation is spent; the chain and the
	// client are free again, and the key's next record is a new incarnation.
	id := govern(cur, stale)
	println("a request built for incarnation 1:", decided(id), "| its route:", ibcgov.DecisionRoute(id) == d)
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), d, "0:"+string(a1))))
	println("re-created: incarnation", ibcgov.Incarnation(d), "seat 0", ibcgov.Seat(d, 0) == a1, "flags", len(ibcgov.Flags(d, "")))
	// A recovery of the provisional client is the route's decision; its
	// substitute is checked, never claimed, so a drop leaves no client of
	// the route behind.
	sub := chainClient(cur, 4, "client-9")
	rec := govern(cur, ibcgov.NewRecoverClientRequest(cross(cur), d, sub))
	r, _ := ibcgov.ClientRoute(sub)
	println("a recovery of the provisional client:", ibcgov.DecisionRoute(rec) == d, "| its substitute claimed:", r != "")
	govern(cur, ibcgov.NewCancelRequest(cross(cur), rec))

	// Candidate flags: a seat of each of two routes flags the same candidate
	// client; each counts toward its own route, and only A's follow the
	// candidate into A.
	a := chainClient(cur, 1, "client-0")
	b := chainClient(cur, 2, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), a, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), b, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), a, a)))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), a, "0:"+string(a0))))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), b, "0:"+string(b0))))
	x := chainClient(cur, 1, "gnoland-x")
	flagAs(cur, a0, a, x, ibcgov.FnPayouts)
	flagAs(cur, b0, b, x, ibcgov.FnPayouts)
	println("candidate flags: A's", ibcgov.Flags(a, x), "| B's", ibcgov.Flags(b, x))
	replace := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), a, x, 0))
	println("B flags A's claimed candidate:", revive(func() { flagAs(cur, b0, b, x, ibcgov.FnSends) }))
	execute(cur, replace)
	println("replaced:", decided(replace))
	println("A's payouts flagged:", ibcgov.Flagged(a, ibcgov.FnPayouts), "| B's flag stays B's:", ibcgov.Flags(b, x), "| B's payouts:", ibcgov.Flagged(b, ibcgov.FnPayouts))
	// B's seat still clears its own flag on the client that joined A.
	clearAs(cur, b0, b, x, ibcgov.FnPayouts)
	println("B cleared its flag on A's new client:", len(ibcgov.Flags(b, x)), "| A's payouts still flagged:", ibcgov.Flagged(a, ibcgov.FnPayouts))
}

// Output:
// provisional: true enrolled: false incarnation 1
// flagged before enrolment: true
// another client of the chain: ibcgov: route ethereum-1 is on ethereum chain 3, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3 already: one route per counterparty chain
// seats for another client of the chain: ibcgov: route ethereum-1 is on ethereum chain 3, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3 already: one route per counterparty chain
// enrolled: applied - enroll (adopting its provisional record)
// adopted: seat 0 true credits flagged true incarnation 1
// drop an enrolled route: ibcgov: route ethereum-1 is enrolled: only a provisional record is dropped
// a seat occupied: ibcgov: seat 0 of route ethereum-3 is occupied: vacate every seat first
// vacated on day 21: applied - seats 0,1 of route ethereum-3 | held: true
// while it lingers: ibcgov: route ethereum-3's hold stands, its 24-hour linger included
// stale flag entries: ibcgov: route ethereum-3 still has flag entries: clear or prune them first (PruneFlags)
// pruned: 2
// another decision pending: ibcgov: route ethereum-3 has pending decisions
// a drop executed with another decision pending: spent - spent: route ethereum-3 has pending decisions | record: true
// dropped: applied - dropped the provisional record of route ethereum-3 (incarnation 1) | record: false
// a request built for incarnation 1: spent - spent: route ethereum-3's record changed since the request was built (incarnation 1) | its route: true
// re-created: incarnation 2 seat 0 true flags 0
// a recovery of the provisional client: true | its substitute claimed: false
// candidate flags: A's slice[("payouts seat 0 at 1243121503" string)] | B's slice[("payouts seat 0 at 1243121503" string)]
// B flags A's claimed candidate: ibcgov: ethereum-7 belongs to route ethereum-5
// replaced: applied - replace: client ethereum-5 retired for transfers, meters emptied, 1 flags of ethereum-7 moved to the route; governance epoch 1 stays over ethereum-5 until IBCAdmin's epoch notices arrive
// A's payouts flagged: true | B's flag stays B's: slice[("payouts seat 0 at 1243121503" string)] | B's payouts: false
// B cleared its flag on A's new client: 0 | A's payouts still flagged: true
