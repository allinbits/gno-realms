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

// Before the binding any Ethereum deployment enrols, but the binding is
// refused while an enrolled route authenticates another deployment than
// the one it binds over (design review r17 #1), when requested and, if
// requested before that route enrolled, when it executes.
func main(cur realm) {
	route := client(cur, ethtesting.ClientState())
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector), bridge)))
	bind := govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)) // before the other route
	cs := ethtesting.ClientState()
	cs.ChainID = 1
	other := client(cur, cs)
	enrol := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), other, string(collector), bridge))
	execute(cur, enrol)
	println("another deployment before the binding:", decided(enrol))
	ibcgov.Execute(cross(cur), bind)
	println("the binding requested before it:", decided(bind), "| epoch", ibcgov.Epoch())
	println("the binding requested after it:", revive(func() {
		govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route))
	}))
}

// Output:
// another deployment before the binding: applied - enroll
// the binding requested before it: spent - spent: route ethereum-2 authenticates another Ethereum deployment than ethereum-1: one governance channel serves one deployment | epoch 0
// the binding requested after it: ibcgov: route ethereum-2 authenticates another Ethereum deployment than ethereum-1: one governance channel serves one deployment
