// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/binary"
	"strings"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
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

func payload(body []byte) types.Payload {
	return types.Payload{SourcePort: ibcgov.GovPort, DestinationPort: ibcgov.GovDestPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: body}
}

func appAck(epoch uint32, seq uint64, status, redispatch byte) []byte {
	b := binary.BigEndian.AppendUint32(nil, epoch)
	b = binary.BigEndian.AppendUint64(b, seq)
	return append(b, status, redispatch)
}

// ackAsCore delivers an acknowledgement of a governance packet sent over
// client, carrying body, as the core does after verifying it.
func ackAsCore(cur realm, client string, transport uint64, body, ack []byte) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	if err := app.OnAcknowledgementPacket(cross(cur), client, "client-0", transport, ack, payload(body)); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func state(route string) string {
	status, redispatch, inFlight, sends, _ := ibcgov.DispatchState(route, 1, 1)
	return "status " + string(rune('0'+status)) + " redispatch " + boolText(redispatch) + " in flight " + boolText(inFlight) + " sends " + string(rune('0'+sends))
}

func boolText(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// Two routes, two chains, one ibcgov (ADR 0007): each enrols and binds its
// own channel; numbering, acknowledgements and re-dispatches are per route;
// seats, flags and holds are per route, a key may sit on both; a route's hold
// defers its own decisions and every global one, never another route's;
// a gno client belongs to one route.
func main(cur realm) {
	a := chainClient(cur, 1, "client-0")
	b := chainClient(cur, 2, "client-0") // the same router client id on another chain
	// Clients made now: once a relayer is listed, only listed relayers
	// create clients.
	other := chainClient(cur, 1, "gnoland-y")
	stranger := chainClient(cur, 3, "gnoland-z")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), a, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), b, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), a, a)))
	println("A bound, B not:", ibcgov.Epoch(a), ibcgov.Epoch(b))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), b, b)))
	println("both bound:", ibcgov.Epoch(a), "over", ibcgov.EpochClient(a), "|", ibcgov.Epoch(b), "over", ibcgov.EpochClient(b))

	// Numbering is per route: both dispatch epoch 1 seq 1, byte-identical.
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), a, 2, ""))
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), b, 2, ""))
	bodyA, bodyB := ibcgov.DispatchBody(a, 1, 1), ibcgov.DispatchBody(b, 1, 1)
	println("A and B seq 1, identical bytes:", string(bodyA) == string(bodyB))
	// An acknowledgement over A's client answers A's dispatch only.
	ackAsCore(cur, a, ibcgov.DispatchTransport(a, 1, 1), bodyA, appAck(1, 1, ibcgov.StatusRecorded, 0))
	println("A:", state(a), "| B:", state(b))
	ackAsCore(cur, b, ibcgov.DispatchTransport(b, 1, 1), bodyB, appAck(1, 1, ibcgov.StatusRecorded, 1))
	ibcgov.Redispatch(cross(cur), b, 1, 1)
	println("B re-dispatched over its own client:", state(b), "| A:", state(a))
	println("render:", strings.Contains(ibcgov.Render("dispatch/"+b+"/1/1"), "\"sends\":2"), ibcgov.Render("dispatch/1/1"))

	// Seats are per route; one key may hold seats on both.
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), a, "0:"+string(a0)+",1:"+string(a1))))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), b, "0:"+string(b0)+",1:"+string(both))))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), a, "2:"+string(both))))
	println("seats:", ibcgov.SeatOf(a, both), ibcgov.SeatOf(b, both), ibcgov.SeatOf(a, b0))
	println("a seat of B flags A:", revive(func() { flagAs(cur, b0, a, a, ibcgov.FnSends) }))
	println("a seat of B names A as its target:", revive(func() { flagAs(cur, b0, b, a, ibcgov.FnSends) }))
	// The key on both routes flags B: B's sends stop, A's do not.
	flagAs(cur, both, b, b, ibcgov.FnSends)
	println("B sends flagged:", ibcgov.Flagged(b, ibcgov.FnSends), "| A:", ibcgov.Flagged(a, ibcgov.FnSends))

	// A's hold: A's queued decisions and global ones wait, B's do not.
	denomA := govern(cur, ibcgov.NewSetFeeCollectorRequest(cross(cur), a, string(testutils.TestAddress("fees-a"))))
	denomB := govern(cur, ibcgov.NewSetFeeCollectorRequest(cross(cur), b, string(testutils.TestAddress("fees-b"))))
	global := govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("relayer"))))
	flagAs(cur, a0, a, a, ibcgov.FnCredits)
	flagAs(cur, a1, a, a, ibcgov.FnCredits)
	println("held: A", ibcgov.Held(a), "B", ibcgov.Held(b), "any", ibcgov.AnyHeld())
	advance(7*24*time.Hour + time.Second)
	println("A's decision:", revive(func() { ibcgov.Execute(cross(cur), denomA) }))
	ibcgov.Execute(cross(cur), denomB)
	println("B's decision:", decided(denomB))
	ibcgov.Execute(cross(cur), global) // the first deferral records its anchor
	println("a global decision:", decided(global), "|", revive(func() { ibcgov.Execute(cross(cur), global) }))

	// A route unpause is spent by its own route's hold only.
	unA := govern(cur, ibcgov.NewUnpauseRouteRequest(cross(cur), a, a, "credits"))
	unB := govern(cur, ibcgov.NewUnpauseRouteRequest(cross(cur), b, b, "sends"))
	println("unpause A:", decided(unA))
	println("unpause B:", decided(unB), "| B sends flagged:", ibcgov.Flagged(b, ibcgov.FnSends))
	clearAs(cur, a0, a, a, ibcgov.FnCredits)
	clearAs(cur, a1, a, a, ibcgov.FnCredits)
	advance(24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), denomA)
	ibcgov.Execute(cross(cur), global)
	println("after A's hold:", decided(denomA), "|", decided(global))

	// A gno client belongs to one route: B's client is never A's local
	// client, nor a counterparty A registers on its IBCAdmin.
	println("B's client as A's local client:", revive(func() {
		govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), a, "client-0", "gnoland-x", b))
	}))
	println("B's client in A's kind 6 op 1:", revive(func() {
		govern(cur, ibcgov.NewEthClientRequest(cross(cur), a, 1, "gnoland-x", b, "6d61696e", "0x1111111111111111111111111111111111111111", strings.Repeat("ab", 32)))
	}))
	println("another chain's client in A's kind 6 op 1:", revive(func() {
		govern(cur, ibcgov.NewEthClientRequest(cross(cur), a, 1, "gnoland-z", stranger, "6d61696e", "0x1111111111111111111111111111111111111111", strings.Repeat("ab", 32)))
	}))
	op1 := govern(cur, ibcgov.NewEthClientRequest(cross(cur), a, 1, "gnoland-y", other, "6d61696e", "0x1111111111111111111111111111111111111111", strings.Repeat("ab", 32)))
	route, permanent := ibcgov.ClientRoute(other)
	println("A's own client in its kind 6 op 1:", decided(op1), "| claimed by", route == a, permanent)
}

// Output:
// A bound, B not: 1 0
// both bound: 1 over ethereum-1 | 1 over ethereum-2
// A and B seq 1, identical bytes: true
// A: status 1 redispatch no in flight no sends 1 | B: status 0 redispatch no in flight yes sends 1
// B re-dispatched over its own client: status 1 redispatch no in flight yes sends 2 | A: status 1 redispatch no in flight no sends 1
// render: true null
// seats: 2 1 -1
// a seat of B flags A: ibcgov: not a guardian or a watch key of route ethereum-1: g1vgkkwatpwfjxjctw95c97h6lta047h6lje2lsg
// a seat of B names A as its target: ibcgov: a seat of route ethereum-2 flags its own route or a candidate client, not route ethereum-1
// B sends flagged: true | A: false
// held: A true B false any true
// A's decision: ibcgov: decision 10 is deferred: route ethereum-1's guardian hold stands since 1238801497
// B's decision: applied - collector
// a global decision: pending - queued 7 days | ibcgov: decision 12 is deferred: a guardian hold first deferred it on 1238801497, until 1240615897
// unpause A: spent - spent: route ethereum-1's guardian hold stands, which spends its unpauses
// unpause B: applied - cleared 1 flags of route ethereum-2 | B sends flagged: false
// after A's hold: applied - collector | applied - core add relayer
// B's client as A's local client: ibcgov: ethereum-2's counterparty is not gnoland-x
// B's client in A's kind 6 op 1: ibcgov: the gno client ethereum-2 is paired with client-0, not gnoland-x
// another chain's client in A's kind 6 op 1: ibcgov: ethereum-4 authenticates (chain 3, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600), not route ethereum-1's (chain 1, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600)
// A's own client in its kind 6 op 1: applied - dispatched as epoch 1 seq 2 | claimed by true true
