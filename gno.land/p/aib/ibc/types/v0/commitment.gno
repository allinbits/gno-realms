package types

import (
	"crypto/sha256"

	"gno.land/p/aib/encoding/v0"
)

// CommitPacket returns the V2 packet commitment bytes. The commitment consists of:
// ha256_hash(0x02 + sha256_hash(destinationClient) + sha256_hash(timeout) + sha256_hash(payload)) from a given packet.
// This results in a fixed length preimage of 32 bytes.
// NOTE: A fixed length preimage is ESSENTIAL to prevent relayers from being able
// to malleate the packet fields and create a commitment hash that matches the original packet.
func CommitPacket(packet Packet) []byte {
	var buf []byte
	destIDHash := sha256.Sum256([]byte(packet.DestinationClient))
	buf = append(buf, destIDHash[:]...)

	timeoutBytes := encoding.Uint64ToBigEndian(packet.TimeoutTimestamp)
	timeoutHash := sha256.Sum256(timeoutBytes)
	buf = append(buf, timeoutHash[:]...)

	var appBytes []byte
	for _, payload := range packet.Payloads {
		appBytes = append(appBytes, hashPayload(payload)...)
	}
	appHash := sha256.Sum256(appBytes)
	buf = append(buf, appHash[:]...)

	buf = append([]byte{byte(2)}, buf...)

	hash := sha256.Sum256(buf)
	return hash[:]
}

// CommitPacketReceipt returns the value the IBC core stores at a packet's
// receipt path (ICS24 receipt key: destination client ‖ 0x02 ‖ sequence) when
// it receives the packet. ibc-go stores the constant 0x02 there, which says
// that some packet was received at the sequence but not which; this value
// identifies the packet, so a reconciliation can tell which packet occupies a
// sequence (ADR pr6375 R19, §7.12), as eureka's
// keccak256(abi.encode(packet)) does on Ethereum. The encoding, fixed-length
// so no field can be malleated into another:
//
//	sha256(0x03 ‖ uint64be(sequence) ‖ sha256(sourceClient) ‖ CommitPacket(packet))
//
// CommitPacket covers the destination client, the timeout and every payload
// (ports, version, encoding and value); the sequence and the source client
// complete it. Counterparties only ever prove the absence of a receipt (for a
// timeout), which this value does not affect.
func CommitPacketReceipt(packet Packet) []byte {
	buf := []byte{byte(3)}
	buf = append(buf, encoding.Uint64ToBigEndian(packet.Sequence)...)
	srcHash := sha256.Sum256([]byte(packet.SourceClient))
	buf = append(buf, srcHash[:]...)
	buf = append(buf, CommitPacket(packet)...)
	hash := sha256.Sum256(buf)
	return hash[:]
}

// CommitAcknowledgement returns the V2 acknowledgement commitment bytes.
// The commitment consists of:
// sha256_hash(0x02 + sha256_hash(ack1) + sha256_hash(ack2) + ...) from a given
// acknowledgement.
func CommitAcknowledgement(acknowledgement Acknowledgement) []byte {
	var buf []byte
	for _, ack := range acknowledgement.AppAcknowledgements {
		hash := sha256.Sum256(ack)
		buf = append(buf, hash[:]...)
	}

	buf = append([]byte{byte(2)}, buf...)

	hash := sha256.Sum256(buf)
	return hash[:]
}

// hashPayload returns the hash of the payload.
func hashPayload(data Payload) []byte {
	var buf []byte
	sourceHash := sha256.Sum256([]byte(data.SourcePort))
	buf = append(buf, sourceHash[:]...)
	destHash := sha256.Sum256([]byte(data.DestinationPort))
	buf = append(buf, destHash[:]...)
	payloadVersionHash := sha256.Sum256([]byte(data.Version))
	buf = append(buf, payloadVersionHash[:]...)
	payloadEncodingHash := sha256.Sum256([]byte(data.Encoding))
	buf = append(buf, payloadEncodingHash[:]...)
	payloadValueHash := sha256.Sum256(data.Value)
	buf = append(buf, payloadValueHash[:]...)
	hash := sha256.Sum256(buf)
	return hash[:]
}
