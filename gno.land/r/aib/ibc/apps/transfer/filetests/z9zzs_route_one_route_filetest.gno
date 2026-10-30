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
func client(cur realm, cs ethereum.ClientState, counterparty string) string {
	id := core.CreateClient(cross(cur), cs, ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, counterparty)
	return id
}

// One governance channel serves one Ethereum route, ever (code review r58,
// design review r18): IBCAdmin replaces and recovers only the route of the
// client it governs over. Two enrolments requested together: the first
// applies, the second is spent; another one is refused when requested,
// before the binding and after it, whatever its router client or
// deployment. The binding over the route's client applies.
func main(cur realm) {
	a := client(cur, ethtesting.ClientState(), "client-0")
	b := client(cur, ethtesting.ClientState(), "client-1")
	enrolA := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), a, string(collector), bridge))
	enrolB := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), b, string(collector), bridge))
	execute(cur, enrolA)
	ibcgov.Execute(cross(cur), enrolB)
	println("the first enrolment:", decided(enrolA))
	println("the second, requested with it:", decided(enrolB))
	c := client(cur, ethtesting.ClientState(), "client-2")
	println("another route before the binding:", revive(func() {
		govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), c, string(collector), bridge))
	}))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), a)))
	println("bound: epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())
	cs := ethtesting.ClientState()
	cs.ChainID = 1
	d := client(cur, cs, "client-3")
	for _, x := range []string{c, d} {
		println("another route after the binding:", revive(func() {
			govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), x, string(collector), bridge))
		}))
	}
}

// Output:
// the first enrolment: applied - enroll
// the second, requested with it: spent - spent: the governance channel serves one Ethereum route, enrolled already: a second route would have no Ethereum replacement or recovery path
// another route before the binding: ibcgov: the governance channel serves one Ethereum route, enrolled already: a second route would have no Ethereum replacement or recovery path
// bound: epoch 1 over ethereum-1
// another route after the binding: ibcgov: the governance channel serves one Ethereum route, enrolled already: a second route would have no Ethereum replacement or recovery path
// another route after the binding: ibcgov: the governance channel serves one Ethereum route, enrolled already: a second route would have no Ethereum replacement or recovery path
