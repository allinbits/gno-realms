package testing

import (
	"testing"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
)

func packet(seq uint64) types.Packet {
	return types.Packet{
		Sequence: seq, SourceClient: "client-0", DestinationClient: "ethereum-1", TimeoutTimestamp: 1234571490,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/json", Value: []byte{byte(seq)}}},
	}
}

// The light client verifies the fake router's proofs: every stored
// commitment, and the absence of one never stored.
func TestRouterProofsVerify(t *testing.T) {
	r := NewRouter()
	for seq := uint64(1); seq <= 40; seq++ {
		r.CommitPacket(packet(seq))
	}
	c := ethereum.NewEthLightClient()
	if err := c.Initialize(ClientState(), ConsensusStateWithRoot(r.StateRoot())); err != nil {
		t.Fatal(err)
	}
	h := types.NewHeight(0, 72)
	path := func(key []byte) types.MerklePath { return types.BuildMerklePath([][]byte{{}}, key) }
	for seq := uint64(1); seq <= 40; seq++ {
		p := packet(seq)
		if err := c.VerifyMembershipProof(h, r.Proof(), path(host.PacketCommitmentKey(p.SourceClient, seq)), types.CommitPacket(p)); err != nil {
			t.Fatalf("seq %d: %v", seq, err)
		}
	}
	if err := c.VerifyNonMembershipProof(h, r.Proof(), path(host.PacketCommitmentKey("client-0", 41))); err != nil {
		t.Fatal(err)
	}
	if err := c.VerifyMembershipProof(h, r.Proof(), path(host.PacketCommitmentKey("client-0", 41)), types.CommitPacket(packet(41))); err == nil {
		t.Fatalf("proved a commitment never stored")
	}
}
