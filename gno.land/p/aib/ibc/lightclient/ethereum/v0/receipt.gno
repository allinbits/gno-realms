package ethereum

import (
	"gno.land/p/aib/encoding/abi/v0"
	"gno.land/p/aib/ibc/types/v0"
)

// PacketReceiptCommitment is the value an Ethereum ICS26 router
// (solidity-ibc-eureka) stores at a received packet's ICS24 receipt path:
// keccak256(abi.encode(packet)), the packet as the router's Packet struct
// (sequence, sourceClient, destClient, timeoutTimestamp, payloads with
// sourcePort, destPort, version, encoding, value). A reconciliation
// recomputes it to tell the packet's receipt from another's (ADR pr6375
// §7.12).
func PacketReceiptCommitment(p types.Packet) []byte {
	payloads := make([]abi.Value, len(p.Payloads))
	for i, pl := range p.Payloads {
		payloads[i] = abi.Tuple(abi.String(pl.SourcePort), abi.String(pl.DestinationPort), abi.String(pl.Version),
			abi.String(pl.Encoding), abi.Bytes(pl.Value))
	}
	return keccak(abi.Encode(abi.Tuple(abi.Uint64(p.Sequence), abi.String(p.SourceClient), abi.String(p.DestinationClient),
		abi.Uint64(p.TimeoutTimestamp), abi.Array(payloads...))))
}

// ProvenValue is the value proof establishes for the router's commitment at
// path at height, zero (32 zero bytes) if none is stored: what a
// reconciliation reads to tell a delivered, refundable or collided packet
// apart.
func (c *EthLightClient) ProvenValue(height types.Height, proof any, path types.MerklePath) ([]byte, error) {
	return c.provenCommitment(height, proof, path)
}
