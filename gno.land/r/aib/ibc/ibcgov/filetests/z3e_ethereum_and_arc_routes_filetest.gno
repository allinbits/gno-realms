// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	arctesting "gno.land/p/aib/ibc/lightclient/arc/testing/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ethrelay"
	"gno.land/r/aib/ibc/ibcgov"
)

const (
	ethBridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"
	// the ICS20 transfer and IBCAdmin of the Arc route; its router is the
	// one the Arc client reads (appended below).
	arcApps = " 0x00000000000000000000000000000000000c0002 0x00000000000000000000000000000000000c0003"
)

var (
	collector = testutils.TestAddress("collector")
	e0        = testutils.TestAddress("eth-guardian-0")
	e1        = testutils.TestAddress("eth-guardian-1")
	r0        = testutils.TestAddress("arc-guardian-0")
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

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

func flagAs(cur realm, who address, route, target, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.SetFlag(cross(cur), route, target, fn, "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

// An Ethereum route and an Arc route side by side (ADR 0007, ADR 0008): each
// enrols and binds its own governance channel over its own router client,
// on its own chain, numbering its decisions from 1; seats and holds are per
// route, so the Ethereum route's hold defers its own decisions, never the
// Arc route's; an Arc client cannot replace the Ethereum route's, a
// replacement having to authenticate the route's recorded identity.
func main(cur realm) {
	// The Ethereum route, on the Ethereum fixtures' clock.
	eth := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), eth, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), eth, string(collector), ethBridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), eth, eth)))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), eth, "0:"+string(e0)+",1:"+string(e1))))
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), eth, 2, ""))
	println("ethereum seq 1 committed over its client:", len(core.PacketCommitment(eth, ibcgov.DispatchTransport(eth, 1, 1))) == 32)

	// The Arc route, on Arc testnet data. The clock starts a minute before
	// the fixture's verification time (its block is 9 s older, within the
	// 90 s drift), so its enrolment and binding, 7 days each, land within
	// its 14-day trusting period.
	testing.SetContext(testing.Context{Time: time.Unix(arctesting.Time-60, 0)})
	arc := ethrelay.CreateArcClient(cross(cur), arctesting.Creation)
	core.RegisterCounterparty(cross(cur), arc, [][]byte{{}}, "client-0")
	_, router := core.ClientRouteIdentity(arc)
	println("router clients:", core.IsRouterClient(eth), core.IsRouterClient(arc))
	println("chains:", core.ClientChainIdentity(eth) != core.ClientChainIdentity(arc))
	enrol := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), arc, string(collector), router+arcApps))
	execute(cur, enrol)
	println("Arc enrolled:", decided(enrol), "| routes:", ibcgov.IsRoute(eth), ibcgov.IsRoute(arc))
	bind := govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), arc, arc))
	execute(cur, bind)
	println("Arc bound:", decided(bind))
	println("epochs:", ibcgov.Epoch(eth), "over", ibcgov.EpochClient(eth), "|", ibcgov.Epoch(arc), "over", ibcgov.EpochClient(arc))

	// Each route numbers its own decisions from 1 and sends them over its
	// own client.
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), arc, 2, ""))
	tA := ibcgov.DispatchTransport(arc, 1, 1)
	println("arc seq 1 committed over its client:", len(core.PacketCommitment(arc, tA)) == 32)
	println("same bytes, own channels:", string(ibcgov.DispatchBody(eth, 1, 1)) == string(ibcgov.DispatchBody(arc, 1, 1)))

	// An Arc client never takes the Ethereum route's place: a replacement
	// must authenticate the route's recorded identity.
	spare := ethrelay.CreateArcClient(cross(cur), arctesting.Creation)
	core.RegisterCounterparty(cross(cur), spare, [][]byte{{}}, "client-0")
	println("arc client for the ethereum route:", revive(func() {
		govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), eth, spare, 0))
	}))

	// The Ethereum route's hold defers its own decisions, never the Arc
	// route's.
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), arc, "0:"+string(r0))))
	feesEth := govern(cur, ibcgov.NewSetFeeCollectorRequest(cross(cur), eth, string(testutils.TestAddress("fees-eth"))))
	feesArc := govern(cur, ibcgov.NewSetFeeCollectorRequest(cross(cur), arc, string(testutils.TestAddress("fees-arc"))))
	flagAs(cur, e0, eth, eth, ibcgov.FnCredits)
	flagAs(cur, e1, eth, eth, ibcgov.FnCredits)
	println("held: ethereum", ibcgov.Held(eth), "arc", ibcgov.Held(arc))
	advance(7*24*time.Hour + time.Second)
	println("ethereum's decision:", revive(func() { ibcgov.Execute(cross(cur), feesEth) }))
	ibcgov.Execute(cross(cur), feesArc)
	println("arc's decision:", decided(feesArc))
	println("a seat of arc flags ethereum:", revive(func() { flagAs(cur, r0, eth, eth, ibcgov.FnSends) }))

}

// Output:
// ethereum seq 1 committed over its client: true
// router clients: true true
// chains: true
// Arc enrolled: applied - enroll | routes: true true
// Arc bound: applied - route arc-2's governance epoch 1 over arc-2
// epochs: 1 over ethereum-1 | 1 over arc-2
// arc seq 1 committed over its client: true
// same bytes, own channels: true
// arc client for the ethereum route: ibcgov: arc-3 authenticates (arc chain 5042002, registry 0x3600000000000000000000000000000000000002, router 0x00000000000000000000000000000000000000aa, commitment slot 0x0000000000000000000000000000000000000000000000000000000000000000), not route ethereum-1's (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600)
// held: ethereum true arc false
// ethereum's decision: ibcgov: decision 9 is deferred: route ethereum-1's guardian hold stands since 1795515219
// arc's decision: applied - collector
// a seat of arc flags ethereum: ibcgov: not a guardian or a watch key of route ethereum-1: g1v9exxtt8w4shyerfv9hz6vzlta047h6lgrhav7
