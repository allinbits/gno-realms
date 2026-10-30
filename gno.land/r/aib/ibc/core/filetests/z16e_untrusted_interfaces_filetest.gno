// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/params"
	"chain/runtime/unsafe"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/ics23/v0"
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

// evilProof is a commitment proof of the caller's own type.
type evilProof struct{}

func (evilProof) GetExist() *ics23.ExistenceProof       { forge(); return &ics23.ExistenceProof{} }
func (evilProof) GetNonexist() *ics23.NonExistenceProof { forge(); return &ics23.NonExistenceProof{} }

// evilMessage is a client message of the caller's own type.
type evilMessage struct{}

func (evilMessage) ClientType() string   { forge(); return ethtesting.ClientState().ClientType() }
func (evilMessage) ValidateBasic() error { forge(); return nil }

// evilData is an Ext proof payload of the caller's own type.
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
// (Codex round 19): a proof, client message or Ext payload of the caller's
// own type is refused before any of its code runs, so it cannot write under
// the core's parameter namespace.
func main(cur realm) {
	eth := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), eth, [][]byte{{}}, "client-0")
	tm := core.CreateClient(cross(cur), tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2)),
		tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash()))
	core.RegisterCounterparty(cross(cur), tm, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-42")
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/json", Value: []byte("{}")}
	timeout := uint64(time.Now().Add(time.Hour).Unix())

	// An acknowledgement for an unused sequence, which would otherwise end
	// as a no-op with nothing verified.
	println("ack, own proof type:", refused(func() {
		core.Acknowledgement(cross(cur), types.MsgAcknowledgement{
			Packet:          types.Packet{Sequence: 9, SourceClient: eth, DestinationClient: "client-0", TimeoutTimestamp: timeout, Payloads: []types.Payload{payload}},
			Acknowledgement: types.Acknowledgement{AppAcknowledgements: [][]byte{[]byte("ok")}},
			ProofAcked:      []ics23.CommitmentProof{evilProof{}},
			ProofHeight:     types.NewHeight(0, 72),
		})
	}))
	// A membership proof on a Tendermint client.
	println("recv on tendermint, own proof type:", refused(func() {
		core.RecvPacket(cross(cur), types.MsgRecvPacket{
			Packet:          types.Packet{Sequence: 1, SourceClient: "07-tendermint-42", DestinationClient: tm, TimeoutTimestamp: timeout, Payloads: []types.Payload{payload}},
			ProofCommitment: []ics23.CommitmentProof{evilProof{}, evilProof{}},
			ProofHeight:     types.NewHeight(2, 2),
		})
	}))
	println("timeout on tendermint, own proof type:", refused(func() {
		core.Timeout(cross(cur), types.MsgTimeout{
			Packet:          types.Packet{Sequence: 1, SourceClient: tm, DestinationClient: "07-tendermint-42", TimeoutTimestamp: 1, Payloads: []types.Payload{payload}},
			ProofUnreceived: []ics23.CommitmentProof{evilProof{}, evilProof{}},
			ProofHeight:     types.NewHeight(2, 2),
		})
	}))
	// A client message.
	println("update, own message type:", refused(func() { core.UpdateClient(cross(cur), eth, evilMessage{}) }))
	// An Ext proof whose data is the caller's own type.
	println("recv, own Ext data:", refused(func() {
		core.RecvPacket(cross(cur), types.MsgRecvPacket{
			Packet:      types.Packet{Sequence: 1, SourceClient: "client-0", DestinationClient: eth, TimeoutTimestamp: timeout, Payloads: []types.Payload{payload}},
			ProofHeight: types.NewHeight(0, 72),
			Ext:         extproof.Proof{Data: evilData{}},
		})
	}))
	println("caller code ran:", calls, "times", ranAs)
}

// Output:
// ack, own proof type: refused: commitment proof #0 is not an ics23 proof
// recv on tendermint, own proof type: refused: commitment proof #0 is not an ics23 proof
// timeout on tendermint, own proof type: refused: commitment proof #0 is not an ics23 proof
// update, own message type: refused: the client message must be a light client's own type
// recv, own Ext data: refused: failed packet commitment verification for client (ethereum-1): expected ethereum.MembershipProof, got unknown
// caller code ran: 0 times
