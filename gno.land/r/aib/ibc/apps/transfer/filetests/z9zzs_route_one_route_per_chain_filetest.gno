// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var collector = testutils.TestAddress("collector")

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

// client creates an Ethereum client of the given state, its counterparty
// the router client "client-0".
func client(cur realm, cs ethereum.ClientState, counterparty string) string {
	id := core.CreateClient(cross(cur), cs, ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, counterparty)
	return id
}

// One route per counterparty chain, any number of chains (ADR 0007 §4):
// two enrolments of one chain requested together, the first applies and the
// second is spent; while it is pending its client is that enrolment's, so
// the first route cannot take it; once it is spent, it can (ADR 0007 §2).
// Another client of the chain is refused when requested, before the binding
// and after it, whatever its router client or router. A route of another
// chain enrols and binds its own channel, independently.
func main(cur realm) {
	a := client(cur, ethtesting.ClientState(), "client-0")
	b := client(cur, ethtesting.ClientState(), "client-1")
	c := client(cur, ethtesting.ClientState(), "client-2")
	other := ethtesting.ClientState()
	other.IBCContractAddress = append(make([]byte, 18), 0x0b, 0x09)
	o := client(cur, other, "client-3")
	enrolA := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), a, string(collector), bridge))
	enrolB := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), b, string(collector), bridge))
	execute(cur, enrolA)
	println("the first enrolment:", decided(enrolA))
	println("another client of the chain before the binding:", revive(func() {
		govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), c, string(collector), bridge))
	}))
	println("another router on the chain:", revive(func() {
		govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), o, string(collector), "0x00000000000000000000000000000000000b0009 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"))
	}))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), a, a)))
	println("bound: epoch", ibcgov.Epoch(a), "over", ibcgov.EpochClient(a))
	println("replace by the pending enrolment's client:", revive(func() {
		govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), a, b, 0))
	}))
	// A recovery of the pending enrolment's client is that would-be route's
	// decision; it never makes the tentative claim permanent.
	rec := govern(cur, ibcgov.NewRecoverClientRequest(cross(cur), b, c))
	ibcgov.Execute(cross(cur), enrolB)
	println("the second, requested with the first:", decided(enrolB))
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), rec)
	println("the recovery of its client:", decided(rec))
	println("another client of the chain after the binding:", revive(func() {
		govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), c, string(collector), bridge))
	}))
	// The losing enrolment's claim on its client was released: the client,
	// which authenticates the route, can replace the route's.
	r, _ := ibcgov.ClientRoute(b)
	println("the loser's client belongs to:", r == "")
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), a, b, 0)))
	r, permanent := ibcgov.ClientRoute(b)
	println("replaced by the loser's client:", r == a, permanent)
	// Another chain: its own route, its own channel.
	cs := ethtesting.ClientState()
	cs.ChainID = 1
	d := client(cur, cs, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), d, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), d, d)))
	println("a route of another chain:", ibcgov.IsRoute(d), "epoch", ibcgov.Epoch(d), "over", ibcgov.EpochClient(d), "- the first:", ibcgov.Epoch(a), "over", ibcgov.EpochClient(a))
}

// Output:
// the first enrolment: applied - enroll
// another client of the chain before the binding: ibcgov: route ethereum-1 is on ethereum chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3 already: one route per counterparty chain
// another router on the chain: ibcgov: route ethereum-1 is on ethereum chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3 already: one route per counterparty chain
// bound: epoch 1 over ethereum-1
// replace by the pending enrolment's client: ibcgov: ethereum-2 belongs to route ethereum-2
// the second, requested with the first: spent - spent: route ethereum-1 is on ethereum chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3 already: one route per counterparty chain
// the recovery of its client: spent - spent: ethereum-2 no longer belongs to route ethereum-2
// another client of the chain after the binding: ibcgov: route ethereum-1 is on ethereum chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3 already: one route per counterparty chain
// the loser's client belongs to: true
// replaced by the loser's client: true true
// a route of another chain: true epoch 1 over ethereum-5 - the first: 1 over ethereum-1
