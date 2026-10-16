// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/binary"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

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

// setupRoute creates an Ethereum client, installs transfer impl/v1 and
// enrolls the client as a route, every step a governor decision.
func setupRoute(cur realm) string {
	clientID := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", clientID, string(collector), "", 10_000)))
	advance(7*24*time.Hour + time.Second) // the separate enrollment's delay, kept so the timeline stays
	return clientID
}

func payload(body []byte) types.Payload {
	return types.Payload{SourcePort: ibcgov.GovPort, DestinationPort: ibcgov.GovDestPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: body}
}

// appAck is IBCAdmin's acknowledgement: epoch u32 ‖ seq u64 ‖ status u8 ‖ redispatch u8.
func appAck(epoch uint32, seq uint64, status, redispatch byte) []byte {
	b := binary.BigEndian.AppendUint32(nil, epoch)
	b = binary.BigEndian.AppendUint64(b, seq)
	return append(b, status, redispatch)
}

// asCore delivers an acknowledgement or a timeout of a governance packet as
// the core does after verifying it.
func ackAsCore(cur realm, client string, seq uint64, ack []byte) {
	transport := ibcgov.DispatchTransport(1, seq)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	if err := app.OnAcknowledgementPacket(cross(cur), client, "client-0", transport, ack, payload(ibcgov.DispatchBody(1, seq))); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func timeoutAsCore(cur realm, client string, seq uint64) {
	transport := ibcgov.DispatchTransport(1, seq)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	if err := app.OnTimeoutPacket(cross(cur), client, "client-0", transport, payload(ibcgov.DispatchBody(1, seq))); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func show(seq uint64) {
	status, redispatch, inFlight, sends, event := ibcgov.DispatchState(1, seq)
	println("  seq", seq, "status", status, "redispatch", redispatch, "in flight", inFlight, "sends", sends, "-", event)
}

// The governance channel (ADR pr6375 §5.4, R11): decisions are dispatched over
// the epoch's client as packets on port gov, each under a one-time dispatch
// authorization; only the core calls the callbacks; an acknowledgement records
// IBCAdmin's answer; a timeout, an error acknowledgement, a malformed one or
// redispatch = 1 make the decision re-dispatchable, and Redispatch sends the
// same seq with identical bytes.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	println("before the channel is bound:", revive(func() { govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 2, "")) }))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), client)))
	println("epoch", ibcgov.Epoch(), "over", ibcgov.EpochClient())

	// Seq 1: dispatched at once; the core holds its commitment.
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 2, ""))
	body := ibcgov.DispatchBody(1, 1)
	commitment := core.PacketCommitment(client, 1)
	println("dispatched seq 1:", len(body), "bytes; core commitment:", len(commitment) == 32)
	println(ibcgov.Render("dispatch/1/1"))

	// Nobody else sends on port gov.
	println("direct send:", revive(func() {
		core.SendPacket(cross(cur), types.MsgSendPacket{
			SourceClient: client, TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
			Payloads: []types.Payload{payload(body)},
		})
	}))
	// Only the core calls the callbacks.
	println("foreign ack:", revive(func() {
		var app ibcgov.App
		app.OnAcknowledgementPacket(cross(cur), client, "client-0", 1, appAck(1, 1, ibcgov.StatusRecorded, 0), payload(body))
	}))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	res := app.OnRecvPacket(cross(cur), "client-0", client, 1, payload(body))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("a governance packet received here:", res.Status == types.PacketStatus_Failure)

	// Recorded: final, not re-dispatchable.
	ackAsCore(cur, client, 1, appAck(1, 1, ibcgov.StatusRecorded, 0))
	show(1)
	println("redispatch a recorded decision:", revive(func() { ibcgov.Redispatch(cross(cur), 1, 1) }))

	// Seq 2 times out: re-dispatchable; re-sent with identical bytes.
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 1, "client-0"))
	println("redispatch in flight:", revive(func() { ibcgov.Redispatch(cross(cur), 1, 2) }))
	timeoutAsCore(cur, client, 2)
	show(2)
	before := string(ibcgov.DispatchBody(1, 2))
	ibcgov.Redispatch(cross(cur), 1, 2)
	show(2)
	println("identical bytes:", string(ibcgov.DispatchBody(1, 2)) == before, "; new packet commitment:", len(core.PacketCommitment(client, ibcgov.DispatchTransport(1, 2))) == 32)

	// Seq 3 gets an error acknowledgement (beyond IBCAdmin's window): re-dispatchable.
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), "client-0", 3600))
	ackAsCore(cur, client, 3, types.UniversalErrorAcknowledgement())
	show(3)

	// Seq 4: a cancel beyond the window is acknowledged with redispatch = 1.
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), "3"))
	ackAsCore(cur, client, 4, appAck(1, 4, ibcgov.StatusRecorded, 1))
	show(4)

	// Seq 5: a malformed acknowledgement (wrong seq) leaves it re-dispatchable;
	// a conflict without redispatch is final, with redispatch = 1 it is sent
	// again (redispatch = 1 means re-send, whatever the status).
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), "client-0", 7200))
	ackAsCore(cur, client, 5, appAck(1, 6, ibcgov.StatusRecorded, 0))
	show(5)
	ibcgov.Redispatch(cross(cur), 1, 5)
	ackAsCore(cur, client, 5, appAck(1, 5, ibcgov.StatusConflict, 0))
	show(5)
	println("redispatch after a conflict:", revive(func() { ibcgov.Redispatch(cross(cur), 1, 5) }))

	// A buffered decision waits for its turn on Ethereum: nothing to do here.
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), "client-0", 10800))
	ackAsCore(cur, client, 6, appAck(1, 6, ibcgov.StatusBuffered, 0))
	show(6)
	println("unknown decision:", revive(func() { ibcgov.Redispatch(cross(cur), 1, 99) }))
}

// Output:
// before the channel is bound: ibcgov: the governance channel is not bound
// epoch 1 over ethereum-1
// dispatched seq 1: 110 bytes; core commitment: true
// {"epoch":1,"seq":1,"kind":2,"decision":2,"body":"0100000001000000000000000102000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000","status":0,"redispatch":false,"in_flight":true,"transport":1,"sends":1,"event":"sent as packet 1"}
// direct send: send packet failed for payload #0 app "gov": ibcgov: governance packets are sent by ibcgov's decisions only
// foreign ack: ibcgov: the gov callbacks are the IBC core's, not gno.land/r/aib/main
// a governance packet received here: true
//   seq 1 status 1 redispatch false in flight false sends 1 - acknowledged: recorded
// redispatch a recorded decision: ibcgov: decision 1 is not re-dispatchable (acknowledged: recorded)
// redispatch in flight: ibcgov: decision 2 is not re-dispatchable (sent as packet 3)
//   seq 2 status 0 redispatch true in flight false sends 1 - timed out
//   seq 2 status 0 redispatch false in flight true sends 2 - sent as packet 4
// identical bytes: true ; new packet commitment: true
//   seq 3 status 0 redispatch true in flight false sends 1 - error acknowledgement
//   seq 4 status 1 redispatch true in flight false sends 1 - acknowledged: recorded, redispatch
//   seq 5 status 0 redispatch true in flight false sends 1 - malformed acknowledgement
//   seq 5 status 4 redispatch false in flight false sends 2 - acknowledged: conflict
// redispatch after a conflict: ibcgov: decision 5 is not re-dispatchable (acknowledged: conflict)
//   seq 6 status 2 redispatch false in flight false sends 1 - acknowledged: buffered
// unknown decision: ibcgov: no dispatched decision 1/99
