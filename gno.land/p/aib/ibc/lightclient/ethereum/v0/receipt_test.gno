package ethereum

import (
	"encoding/hex"
	"testing"

	"gno.land/p/aib/ibc/types/v0"
)

// The receipt an Ethereum router stores is keccak256(abi.encode(packet)),
// byte for byte as viem 2.56.3's encodeAbiParameters and keccak256 compute it.
func TestPacketReceiptCommitment(t *testing.T) {
	p := types.Packet{Sequence: 7, SourceClient: "ethereum-1", DestinationClient: "gnoland", TimeoutTimestamp: 1700000000,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/x-solidity-abi", Value: []byte{1, 2, 3}}}}
	got := hex.EncodeToString(PacketReceiptCommitment(p))
	if got != "0b6944f67562b0a5d890d70400de882afa4d225a9945f2d008d8e9e5be7e508f" {
		t.Fatalf("%s", got)
	}
}
