// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

func packet(client string, seq uint64) types.Packet {
	return types.Packet{
		Sequence: seq, SourceClient: "client-0", DestinationClient: client,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads:         []types.Payload{{SourcePort: "appID", DestinationPort: "appID", Encoding: "application/json", Value: []byte("{}"), Version: "v1"}},
	}
}

// A packet an app answered asynchronously before its client was retired
// (ADR pr6375 §7.12) is finalized there: the app that holds the receipt
// writes its acknowledgement on the retired client, so the packet reaches a
// terminal state before the reconciliation. Nothing else is written there.
// The core tells when the pending packet was received (Codex review #14).
func main(cur realm) {
	const client = "ethereum-1"
	p1, p2 := packet(client, 1), packet(client, 2)
	router := ethtesting.NewRouter()
	router.CommitPacket(p1)
	router.CommitPacket(p2)
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")

	app := appstesting.NewApp(cross(cur))
	app.SetOnRecvPacketReturn(types.RecvPacketResult{Status: types.PacketStatus_Async})
	core.RegisterApp(cross(cur), "appID", app)
	for _, p := range []types.Packet{p1, p2} {
		core.RecvPacket(cross(cur), types.MsgRecvPacket{Packet: p, ProofHeight: types.NewHeight(0, 72), Ext: extproof.Proof{Data: router.Proof()}})
	}
	pending, height, ok := core.PendingAsyncAck(id, 1)
	println("pending:", ok, pending.Sequence, "received at height", height)

	retire(cur, id)
	println("retired:", core.IsClientRetired(id))

	ack := types.Acknowledgement{AppAcknowledgements: [][]byte{[]byte("done")}}
	core.WriteAcknowledgement(cross(cur), id, 1, ack)
	_, _, ok = core.PendingAsyncAck(id, 1)
	println("written:", len(core.PacketAcknowledgement(id, 1)) > 0, "| still pending:", ok)
	println("again:", revive(func() { core.WriteAcknowledgement(cross(cur), id, 1, ack) }))
	println("no pending ack:", revive(func() { core.WriteAcknowledgement(cross(cur), id, 3, ack) }))
	core.WriteAcknowledgement(cross(cur), id, 2, ack)
	println("second written:", len(core.PacketAcknowledgement(id, 2)) > 0)
}

func retire(cur realm, id string) {
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.RetireClient(cross(cur), id)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// Output:
// pending: true 1 received at height 123
// retired: true
// written: true | still pending: false
// again: client ethereum-1 is retired
// no pending ack: client ethereum-1 is retired
// second written: true
