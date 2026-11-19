// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/params"
	"chain/runtime/unsafe"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

var (
	calls int    // how often caller-supplied code ran inside a core call
	ranAs string // the realm it ran as
)

// forge is what attacker code would do with the core's realm context: write
// a commitment under the core's parameter namespace.
func forge() {
	calls++
	ranAs = unsafe.CurrentRealm().PkgPath()
	params.SetBytes("forged", []byte("commitment"))
}

// evilMessage is a client message of the caller's own type.
type evilMessage struct{}

func (evilMessage) ClientType() string   { forge(); return ethtesting.ClientState().ClientType() }
func (evilMessage) ValidateBasic() error { forge(); return nil }

// evilData is an Ext payload of the caller's own type.
type evilData struct{}

func (evilData) String() string { forge(); return "" }

func refused(f func()) string {
	r := revive(f)
	if r == nil {
		return "accepted"
	}
	if e, ok := r.(error); ok {
		return "refused: " + e.Error()
	}
	return "refused: " + r.(string)
}

// No entry point of the core runs a method of, or calls, a caller-supplied
// interface value before establishing it is one of our own concrete types
// (Codex round 19): a client message of the caller's own type is refused
// before any of its code runs, and an Ext payload is never read, so neither
// can write under the core's parameter namespace. Proofs are bytes, which
// carry no code.
func main(cur realm) {
	eth := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), eth, [][]byte{{}}, "client-0")
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/json", Value: []byte("{}")}
	timeout := uint64(time.Now().Add(time.Hour).Unix())

	// A client message.
	println("update, own message type:", refused(func() { core.UpdateClient(cross(cur), eth, evilMessage{}) }))
	// An Ext payload of the caller's own type, beside a proof that fails.
	println("recv, own Ext data:", refused(func() {
		core.RecvPacket(cross(cur), types.MsgRecvPacket{
			Packet:          types.Packet{Sequence: 1, SourceClient: "client-0", DestinationClient: eth, TimeoutTimestamp: timeout, Payloads: []types.Payload{payload}},
			ProofCommitment: []byte{0},
			ProofHeight:     types.NewHeight(0, 72),
			Ext:             evilData{},
		})
	}))
	println("caller code ran:", calls, "times", ranAs)
}

// Output:
// update, own message type: refused: the client message must be a light client's own type
// recv, own Ext data: refused: failed packet commitment verification for client (ethereum-1): wire: payload too short
// caller code ran: 0 times
