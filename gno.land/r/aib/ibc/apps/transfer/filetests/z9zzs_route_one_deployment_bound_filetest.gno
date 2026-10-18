// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
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
func client(cur realm, cs ethereum.ClientState) string {
	id := core.CreateClient(cross(cur), cs, ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	return id
}

// One governance channel serves one Ethereum deployment (design review r17
// #1): once bound, a route of another identity is refused when the
// enrolment is requested and, if requested before, when it executes; a
// second route of the bound identity is accepted.
func main(cur realm) {
	route := client(cur, ethtesting.ClientState())
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector), bridge)))
	cs := ethtesting.ClientState()
	cs.ChainID = 1
	early := client(cur, cs)
	pending := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), early, string(collector), bridge)) // before the binding
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())
	ibcgov.Execute(cross(cur), pending)
	println("another deployment, requested before the binding:", decided(pending))
	late := client(cur, cs)
	println("another deployment, after the binding:", revive(func() {
		govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), late, string(collector), bridge))
	}))
	twin := client(cur, ethtesting.ClientState())
	same := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), twin, string(collector), bridge))
	execute(cur, same)
	println("the bound deployment's second route:", decided(same), "| identity shared:", ibcgov.RouteIdentity(twin) == ibcgov.RouteIdentity(route))
}

// Output:
// epoch 1 over ethereum-1
// another deployment, requested before the binding: spent - spent: the governance channel serves the Ethereum deployment (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600), not (chain 1, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600): a route of another deployment would have no Ethereum governance
// another deployment, after the binding: ibcgov: the governance channel serves the Ethereum deployment (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600), not (chain 1, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600): a route of another deployment would have no Ethereum governance
// the bound deployment's second route: applied - enroll | identity shared: true
