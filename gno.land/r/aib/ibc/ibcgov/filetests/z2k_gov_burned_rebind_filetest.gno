// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/binary"
	"encoding/hex"
	"strconv"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

var govRoute, client string

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

func payload(body []byte) types.Payload {
	return types.Payload{SourcePort: ibcgov.GovPort, DestinationPort: ibcgov.GovDestPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: body}
}

func appAck(seq uint64, status byte) []byte {
	b := binary.BigEndian.AppendUint32(nil, 1)
	b = binary.BigEndian.AppendUint64(b, seq)
	return append(b, status, 0)
}

func ack(cur realm, seq uint64, a []byte) {
	transport := ibcgov.DispatchTransport(govRoute, 1, seq)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	if err := app.OnAcknowledgementPacket(cross(cur), client, "client-0", transport, a, payload(ibcgov.DispatchBody(govRoute, 1, seq))); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func show(seq uint64) {
	status, redispatch, inFlight, sends, event := ibcgov.DispatchState(govRoute, 1, seq)
	burned, to, from := ibcgov.DispatchRebind(govRoute, 1, seq)
	println("  seq", seq, "status", status, "burned", burned, "rebound to", to, "from", from, "redispatch", redispatch, "in flight", inFlight, "sends", sends, "-", event)
}

// sameDecision reports whether the copy at seq b carries a's kind and
// params, in an envelope of its own number.
func sameDecision(a, b uint64) bool {
	x, y := ibcgov.DispatchBody(govRoute, 1, a), ibcgov.DispatchBody(govRoute, 1, b)
	_, sx, kx, px, _ := ibcgov.ParseEnvelope(x)
	_, sy, ky, py, _ := ibcgov.ParseEnvelope(y)
	return sx == a && sy == b && kx == ky && hex.EncodeToString(px) == hex.EncodeToString(py)
}

func rebind(cur realm, from, to uint64) string {
	var got []uint64
	if r := revive(func() { got = ibcgov.Rebind(cross(cur), govRoute, 1, from, to) }); r != nil {
		return r.(string)
	}
	s := "bound"
	for _, n := range got {
		s += " " + strconv.FormatUint(n, 10)
	}
	return s
}

// Status 6 (cancelled) on the governance channel, and Rebind (ADR 0004,
// "Burned numbers"): a number acknowledged cancelled that no kind 1 of this
// realm named is burned, one it named is cancelled, both final and never
// re-sent; anyone rebinds burned dispatches of the current epoch to its next
// numbers, in order, with the same kind and params, and a kind 10 whose
// enrolling kind 6 was burned follows that kind 6's copy.
func main(cur realm) {
	client = core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	govRoute = client
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), "ethereum-2", [][]byte{{}}, "gnoland-2")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(ibcgov.Governor()), "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003")))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), govRoute, client)))

	_, _, st, _, ok := ibcgov.ParseAck(appAck(1, ibcgov.StatusCancelled))
	println("status 6 parses:", ok, st)

	// Seq 1 burned (no cancel of ours names it); seq 2 cancelled by our
	// seq 3.
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), govRoute, 2, ""))
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 3600))
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), govRoute, "2"))
	ack(cur, 1, appAck(1, ibcgov.StatusCancelled))
	ack(cur, 2, appAck(2, ibcgov.StatusCancelled))
	ack(cur, 3, appAck(3, ibcgov.StatusRecorded))
	show(1)
	show(2)
	println(ibcgov.Render("dispatch/" + govRoute + "/1/1"))
	println("redispatch burned 1:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 1) }))
	println("redispatch cancelled 2:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 2) }))
	// Status 6 is final short of a governed authorization (a forged 6 on a
	// number IBCAdmin never received: below, seq 21).
	println("a retransmit of cancelled 2 may be decided:", revive(func() { govern(cur, ibcgov.NewRetransmitRequest(cross(cur), govRoute, 1, 2)) }) == nil)
	// Final: a later answer changes nothing.
	ack(cur, 1, appAck(1, ibcgov.StatusRecorded))
	show(1)

	// Seq 4, cancelled by our seq 5 before IBCAdmin held it (an error
	// acknowledgement): never re-sent freely, as IBCAdmin may have dropped
	// the tombstone past its horizon; once per governed authorization.
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 7200))
	ack(cur, 4, types.UniversalErrorAcknowledgement())
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), govRoute, "4"))
	println("redispatch cancelled 4:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 4) }))
	auth := govern(cur, ibcgov.NewRetransmitRequest(cross(cur), govRoute, 1, 4))
	d, _ := ibcgov.Decision(auth)
	println("retransmit 4:", d.State(), "-", d.Note)
	ibcgov.Redispatch(cross(cur), govRoute, 1, 4)
	show(4)
	ack(cur, 4, appAck(4, ibcgov.StatusCancelled))
	show(4)

	// Seqs 6 and 7 burned, 8 recorded: Rebind 6-8 binds 6 and 7, in order,
	// to 9 and 10, same kind and params.
	govern(cur, ibcgov.NewEthRoleRequest(cross(cur), govRoute, true, 1, "0x8888888888888888888888888888888888888888"))
	govern(cur, ibcgov.NewEthSeatsRequest(cross(cur), govRoute, "0:0x1111111111111111111111111111111111111111"))
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 10800))
	ack(cur, 6, appAck(6, ibcgov.StatusCancelled))
	ack(cur, 7, appAck(7, ibcgov.StatusCancelled))
	ack(cur, 8, appAck(8, ibcgov.StatusRecorded))
	println("rebind 6-8:", rebind(cur, 6, 8), "; last seq", ibcgov.LastSeq(govRoute, 1))
	show(6)
	show(7)
	show(8)
	show(9)
	show(10)
	println("9 copies 6:", sameDecision(6, 9), "; 10 copies 7:", sameDecision(7, 10))
	println(ibcgov.Render("dispatch/" + govRoute + "/1/9"))

	// Refusals.
	println("rebind 6 again:", rebind(cur, 6, 6))
	println("rebind 8, recorded:", rebind(cur, 8, 8))
	println("rebind 2, cancelled by us:", rebind(cur, 2, 2))
	println("rebind 4, cancelled by us:", rebind(cur, 4, 4))
	println("rebind 5-4:", rebind(cur, 5, 4))
	println("rebind 0-3:", rebind(cur, 0, 3))
	println("rebind 1-65:", rebind(cur, 1, 65))
	println("rebind 100:", rebind(cur, 100, 100))
	println("rebind epoch 2:", revive(func() { ibcgov.Rebind(cross(cur), govRoute, 2, 1, 1) }))
	println("redispatch burned 6:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 6) }))

	// Seq 11 burned, then cancelled by our seq 12: no longer rebindable.
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 14400))
	ack(cur, 11, appAck(11, ibcgov.StatusCancelled))
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), govRoute, "11"))
	println("rebind 11, cancelled since:", rebind(cur, 11, 11))

	// Seq 13, the kind 6 enrolling gnoland-2, burned; seq 14, the kind 10
	// moving to it, recorded: IBCAdmin keeps it pending until gnoland-2 is
	// enrolled, so only the kind 6 is rebound, and the original kind 10
	// executes after its copy.
	govern(cur, ibcgov.NewEthClientRequest(cross(cur), govRoute, 1, "gnoland-2", "ethereum-2", "6d61696e,2f70762f766d3a676e6f2e6c616e642f722f6169622f6962632f636f72653a",
		"0x5555555555555555555555555555555555555555", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), govRoute, "client-0", "gnoland-2", 21000000, "ethereum-2"))
	expect := ibcgov.LastDecision()
	ack(cur, 13, appAck(13, ibcgov.StatusCancelled))
	ack(cur, 14, appAck(14, ibcgov.StatusRecorded))
	println("rebind 14, the kind 10:", rebind(cur, 14, 14))
	println("rebind 13-14:", rebind(cur, 13, 14))
	println("15 copies 13:", sameDecision(13, 15))
	// The attacker burns the kind 6's copy too: it is rebound again.
	ack(cur, 15, appAck(15, ibcgov.StatusCancelled))
	println("rebind 15:", rebind(cur, 15, 15))
	show(13)
	show(14)
	show(15)
	show(16)

	// Seq 17, acknowledged recorded, is cancelled later on Ethereum (a
	// forged tombstone checked at execution): no acknowledgement reports it,
	// so it is re-sent freely, answered 6, and burned (1 -> 6).
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 18000))
	ack(cur, 17, appAck(17, ibcgov.StatusRecorded))
	ibcgov.Redispatch(cross(cur), govRoute, 1, 17)
	ack(cur, 17, appAck(17, ibcgov.StatusCancelled))
	show(17)
	println("rebind 17:", rebind(cur, 17, 17))

	// Seq 19, acknowledged buffered (perhaps forged), then cancelled by our
	// seq 20: never re-sent freely, whatever its answer, since IBCAdmin may
	// never have held it and dropped the tombstone past its horizon.
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 21600))
	ack(cur, 19, appAck(19, ibcgov.StatusBuffered))
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), govRoute, "19"))
	println("redispatch 19, cancelled by us:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 19) }))

	// Seq 21, the head, never delivered, answered 6 by a forged
	// acknowledgement: burned, its number unfilled on Ethereum. Governance
	// reads IBCAdmin's state and authorizes one re-send of its bytes; IBCAdmin
	// records it, and the answer replaces the 6.
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 25200))
	ack(cur, 21, appAck(21, ibcgov.StatusCancelled))
	before := string(ibcgov.DispatchBody(govRoute, 1, 21))
	println("redispatch 21, burned:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 21) }))
	auth = govern(cur, ibcgov.NewRetransmitRequest(cross(cur), govRoute, 1, 21))
	d, _ = ibcgov.Decision(auth)
	println("retransmit 21:", d.State(), "-", d.Note)
	ibcgov.Redispatch(cross(cur), govRoute, 1, 21)
	show(21)
	println("same bytes:", string(ibcgov.DispatchBody(govRoute, 1, 21)) == before)
	ack(cur, 21, appAck(21, ibcgov.StatusRecorded))
	show(21)
	println("rebind 21, recorded:", rebind(cur, 21, 21))
	println("re-sent freely once recorded:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 21) }) == nil)

	// A grant decided before a cancel is void: seq 22, answered with a
	// (forged) conflict, gets a re-send authorized; our seq 23 then cancels
	// it, and the old grant no longer lets it out (IBCAdmin may have dropped
	// the tombstone past its horizon). A grant decided after the cancel does.
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 28800))
	ack(cur, 22, appAck(22, ibcgov.StatusConflict))
	govern(cur, ibcgov.NewRetransmitRequest(cross(cur), govRoute, 1, 22))
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), govRoute, "22"))
	println("redispatch 22, granted before its cancel:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 22) }))
	auth = govern(cur, ibcgov.NewRetransmitRequest(cross(cur), govRoute, 1, 22))
	d, _ = ibcgov.Decision(auth)
	println("retransmit 22 after the cancel:", d.State())
	ibcgov.Redispatch(cross(cur), govRoute, 1, 22)
	show(22)
	ack(cur, 22, appAck(22, ibcgov.StatusConflict))
	println("a second re-send:", revive(func() { ibcgov.Redispatch(cross(cur), govRoute, 1, 22) }))

	// The epoch moves on: seq 1, still burned, is epoch 1's, decided again
	// in epoch 2.
	execute(cur, expect)
	np := types.Payload{SourcePort: ibcgov.GovDestPort, DestinationPort: ibcgov.GovPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: ibcgov.EpochNotice(2, "gnoland-2")}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	app.OnRecvPacket(cross(cur), "gnoland-2", "ethereum-2", 1, np)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("epoch", ibcgov.Epoch(govRoute))
	println("rebind 1 of epoch 1:", rebind(cur, 1, 1))
}

// Output:
// status 6 parses: true 6
//   seq 1 status 6 burned true rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: cancelled, burned (no cancel of this realm names it): Rebind
//   seq 2 status 6 burned false rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: cancelled by a cancel of this realm
// {"epoch":1,"seq":1,"kind":2,"decision":3,"body":"0100000001000000000000000102000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000","status":6,"redispatch":false,"in_flight":false,"transport":1,"sends":1,"event":"acknowledged: cancelled, burned \u0028no cancel of this realm names it\u0029: Rebind","burned":true,"rebound_to":0,"rebound_from":0}
// redispatch burned 1: ibcgov: decision 1 is burned: Rebind gives it a new number, not sent again without a governed authorization (acknowledged: cancelled, burned (no cancel of this realm names it): Rebind)
// redispatch cancelled 2: ibcgov: decision 2 is cancelled on Ethereum, not sent again without a governed authorization (acknowledged: cancelled by a cancel of this realm)
// a retransmit of cancelled 2 may be decided: true
//   seq 1 status 6 burned true rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: recorded after the cancellation, which stands
// redispatch cancelled 4: ibcgov: decision 4 is not re-dispatchable without a governed authorization (error acknowledgement)
// retransmit 4: applied - authorize one re-send of epoch 1 seq 4: anyone calls Redispatch
//   seq 4 status 0 burned false rebound to 0 from 0 redispatch false in flight true sends 2 - sent as packet 6
//   seq 4 status 6 burned false rebound to 0 from 0 redispatch false in flight false sends 2 - acknowledged: cancelled by a cancel of this realm
// rebind 6-8: bound 9 10 ; last seq 10
//   seq 6 status 6 burned true rebound to 9 from 0 redispatch false in flight false sends 1 - acknowledged: cancelled, burned (no cancel of this realm names it): Rebind; rebound as seq 9
//   seq 7 status 6 burned true rebound to 10 from 0 redispatch false in flight false sends 1 - acknowledged: cancelled, burned (no cancel of this realm names it): Rebind; rebound as seq 10
//   seq 8 status 1 burned false rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: recorded
//   seq 9 status 0 burned false rebound to 0 from 6 redispatch false in flight true sends 1 - sent as packet 10
//   seq 10 status 0 burned false rebound to 0 from 7 redispatch false in flight true sends 1 - sent as packet 11
// 9 copies 6: true ; 10 copies 7: true
// {"epoch":1,"seq":9,"kind":8,"decision":10,"body":"0100000001000000000000000908000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000008888888888888888888888888888888888888888","status":0,"redispatch":false,"in_flight":true,"transport":10,"sends":1,"event":"sent as packet 10","burned":false,"rebound_to":0,"rebound_from":6}
// rebind 6 again: ibcgov: nothing to rebind: decision 6 is rebound already, as seq 9
// rebind 8, recorded: ibcgov: nothing to rebind: decision 8 is not burned (acknowledged: recorded)
// rebind 2, cancelled by us: ibcgov: nothing to rebind: decision 2 is cancelled by a cancel of this realm
// rebind 4, cancelled by us: ibcgov: nothing to rebind: decision 4 is cancelled by a cancel of this realm
// rebind 5-4: ibcgov: an empty range: 5-4
// rebind 0-3: ibcgov: an empty range: 0-3
// rebind 1-65: ibcgov: rebind at most 64 numbers a call
// rebind 100: ibcgov: nothing to rebind: no dispatched decision in 100-100
// rebind epoch 2: ibcgov: epoch 2 is not the current one: a past epoch's decisions are decided again
// redispatch burned 6: ibcgov: decision 6 is burned: Rebind gives it a new number, not sent again without a governed authorization (acknowledged: cancelled, burned (no cancel of this realm names it): Rebind; rebound as seq 9)
// rebind 11, cancelled since: ibcgov: nothing to rebind: decision 11 is cancelled by a cancel of this realm
// rebind 14, the kind 10: ibcgov: nothing to rebind: decision 14 is not burned (acknowledged: recorded)
// rebind 13-14: bound 15
// 15 copies 13: true
// rebind 15: bound 16
//   seq 13 status 6 burned true rebound to 15 from 0 redispatch false in flight false sends 1 - acknowledged: cancelled, burned (no cancel of this realm names it): Rebind; rebound as seq 15
//   seq 14 status 1 burned false rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: recorded
//   seq 15 status 6 burned true rebound to 16 from 13 redispatch false in flight false sends 1 - acknowledged: cancelled, burned (no cancel of this realm names it): Rebind; rebound as seq 16
//   seq 16 status 0 burned false rebound to 0 from 15 redispatch false in flight true sends 1 - sent as packet 17
//   seq 17 status 6 burned true rebound to 0 from 0 redispatch false in flight false sends 2 - acknowledged: cancelled, burned (no cancel of this realm names it): Rebind
// rebind 17: bound 18
// redispatch 19, cancelled by us: ibcgov: decision 19 is not re-dispatchable without a governed authorization (acknowledged: buffered)
// redispatch 21, burned: ibcgov: decision 21 is burned: Rebind gives it a new number, not sent again without a governed authorization (acknowledged: cancelled, burned (no cancel of this realm names it): Rebind)
// retransmit 21: applied - authorize one re-send of epoch 1 seq 21: anyone calls Redispatch
//   seq 21 status 0 burned false rebound to 0 from 0 redispatch false in flight true sends 2 - sent as packet 24
// same bytes: true
//   seq 21 status 1 burned false rebound to 0 from 0 redispatch false in flight false sends 2 - acknowledged: recorded
// rebind 21, recorded: ibcgov: nothing to rebind: decision 21 is not burned (acknowledged: recorded)
// re-sent freely once recorded: true
// redispatch 22, granted before its cancel: ibcgov: decision 22 is not re-dispatchable without a governed authorization (acknowledged: conflict; one re-send authorized; its re-send authorization voided by a cancel)
// retransmit 22 after the cancel: applied
//   seq 22 status 4 burned false rebound to 0 from 0 redispatch false in flight true sends 2 - sent as packet 28
// a second re-send: ibcgov: decision 22 is not re-dispatchable without a governed authorization (acknowledged: conflict)
// epoch 2
// rebind 1 of epoch 1: ibcgov: epoch 1 is not the current one: a past epoch's decisions are decided again
