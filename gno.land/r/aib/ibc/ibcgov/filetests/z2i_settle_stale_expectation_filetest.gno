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

// A recovery expectation adds its router clients to the history only once
// it is recorded: a request built while client-0 carried the epoch, and
// governed after an approved recovery moved Ethereum on to gnoland-c, is
// spent at recording (client-0 is no longer reachable), and gnoland-b,
// which nothing else named, stays out of what a settlement may name.
func main(cur realm) {
	route := client(cur, "client-0") // ethereum-1
	lb := client(cur, "gnoland-b")   // ethereum-2
	lc := client(cur, "gnoland-c")   // ethereum-3
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))

	stale := ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-b", lb)
	execute(cur, govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-c", lc)))
	notice(cur, 2, "gnoland-c", lc)
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())
	id := govern(cur, stale)
	d, _ := ibcgov.Decision(id)
	println("stale expectation:", d.State(), d.Note)
	settle(cur, "gnoland-b")
	settle(cur, "client-0")
}

// Output:
// epoch 2 over ethereum-3
// stale expectation: spent spent: router client client-0 is not reachable from the governance epoch's client: Ethereum is past it
// settle gnoland-b: ibcgov: gnoland-b is not an Ethereum router client of the route, current or retired: client-0, gnoland-c
// settle client-0: dispatched as epoch 2 seq 1
