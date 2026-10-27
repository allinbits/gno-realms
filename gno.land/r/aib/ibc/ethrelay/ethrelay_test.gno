package ethrelay

import (
	"bytes"
	"encoding/hex"
	"testing"

	"gno.land/p/aib/encoding/wire/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/urequire/v0"
)

// The packet message readers, against messages built with the wire writer
// and against vectors the relayers' own encoders produced.

var (
	accountProof = [][]byte{{1, 2, 3}, {4}}
	storageProof = [][]byte{{0xaa, 0xbb}}
)

// encodeProof writes an ethereum.MembershipProof as DecodeMembershipProof
// reads it: list<blob> account_proof, list<blob> storage_proof.
func encodeProof(account, storage [][]byte) []byte {
	w := wire.NewWriter()
	writeBlobs(w, account)
	writeBlobs(w, storage)
	return w.Bytes()
}

func writeBlobs(w *wire.Writer, bs [][]byte) {
	w.Uvarint(uint64(len(bs)))
	for _, b := range bs {
		w.Blob(b)
	}
}

func testPacket() types.Packet {
	return types.Packet{
		Sequence: 7, SourceClient: "client-0", DestinationClient: "ethereum-1", TimeoutTimestamp: 1761903000,
		Payloads: []types.Payload{
			{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/x-solidity-abi", Value: []byte{0xde, 0xad, 0xbe, 0xef}},
			{SourcePort: "port-a", DestinationPort: "port-b", Version: "v2", Encoding: "application/json", Value: []byte(`{"k":1}`)},
		},
	}
}

// writePacket writes a packet message up to its proof height, and the
// acknowledgements when acks is not nil.
func writePacket(p types.Packet, height types.Height, acks [][]byte) *wire.Writer {
	w := wire.NewWriter().Uint(p.Sequence).Str(p.SourceClient).Str(p.DestinationClient).Uint(p.TimeoutTimestamp)
	w.Uvarint(uint64(len(p.Payloads)))
	for _, pl := range p.Payloads {
		w.Str(pl.SourcePort).Str(pl.DestinationPort).Str(pl.Version).Str(pl.Encoding).Blob(pl.Value)
	}
	w.Uint(height.RevisionNumber).Uint(height.RevisionHeight)
	if acks != nil {
		writeBlobs(w, acks)
	}
	return w
}

// readRecv and readAck read a message as RecvPacket and Acknowledgement do.
func readRecv(bz []byte) (types.Packet, types.Height, ethereum.MembershipProof) {
	d := wire.NewReader(bz)
	p, h := readPacket(d)
	return p, h, readProof(d)
}

func readAck(bz []byte) (types.Packet, types.Height, [][]byte, ethereum.MembershipProof) {
	d := wire.NewReader(bz)
	p, h := readPacket(d)
	acks := readBlobs(d)
	return p, h, acks, readProof(d)
}

func assertPacket(t *testing.T, want, got types.Packet) {
	urequire.Equal(t, want.Sequence, got.Sequence)
	urequire.Equal(t, want.SourceClient, got.SourceClient)
	urequire.Equal(t, want.DestinationClient, got.DestinationClient)
	urequire.Equal(t, want.TimeoutTimestamp, got.TimeoutTimestamp)
	urequire.Equal(t, len(want.Payloads), len(got.Payloads))
	for i, w := range want.Payloads {
		g := got.Payloads[i]
		urequire.Equal(t, w.SourcePort, g.SourcePort)
		urequire.Equal(t, w.DestinationPort, g.DestinationPort)
		urequire.Equal(t, w.Version, g.Version)
		urequire.Equal(t, w.Encoding, g.Encoding)
		urequire.True(t, bytes.Equal(w.Value, g.Value), "payload value")
	}
}

func assertBlobs(t *testing.T, want, got [][]byte) {
	urequire.Equal(t, len(want), len(got))
	for i := range want {
		urequire.True(t, bytes.Equal(want[i], got[i]), "blob")
	}
}

func assertProof(t *testing.T, got ethereum.MembershipProof) {
	assertBlobs(t, accountProof, got.AccountProof)
	assertBlobs(t, storageProof, got.StorageProof)
}

// A RecvPacket (and Timeout) message with two payloads round-trips.
func TestReadPacketMessage(t *testing.T) {
	p, height := testPacket(), types.NewHeight(3, 1234)
	bz := writePacket(p, height, nil).Blob(encodeProof(accountProof, storageProof)).Bytes()
	got, h, proof := readRecv(bz)
	assertPacket(t, p, got)
	urequire.Equal(t, uint64(3), h.RevisionNumber)
	urequire.Equal(t, uint64(1234), h.RevisionHeight)
	assertProof(t, proof)
}

// An Acknowledgement message carries its app acknowledgements between the
// proof height and the proof.
func TestReadAcknowledgementMessage(t *testing.T) {
	p, height := testPacket(), types.NewHeight(0, 1234)
	acks := [][]byte{{1}, []byte("ack-2")}
	bz := writePacket(p, height, acks).Blob(encodeProof(accountProof, storageProof)).Bytes()
	got, h, gotAcks, proof := readAck(bz)
	assertPacket(t, p, got)
	urequire.Equal(t, uint64(0), h.RevisionNumber)
	urequire.Equal(t, uint64(1234), h.RevisionHeight)
	assertBlobs(t, acks, gotAcks)
	assertProof(t, proof)
}

// No payloads and no acknowledgements decode as empty lists.
func TestReadEmptyLists(t *testing.T) {
	p := testPacket()
	p.Payloads = nil
	bz := writePacket(p, types.NewHeight(0, 9), [][]byte{}).Blob(encodeProof(nil, nil)).Bytes()
	got, h, acks, proof := readAck(bz)
	assertPacket(t, p, got)
	urequire.Equal(t, uint64(9), h.RevisionHeight)
	urequire.Equal(t, 0, len(acks))
	urequire.Equal(t, 0, len(proof.AccountProof)+len(proof.StorageProof))
}

// Malformed messages are refused with the error that names the fault.
func TestReadRefusals(cur realm, t *testing.T) {
	p, height := testPacket(), types.NewHeight(0, 1234)
	proof := encodeProof(accountProof, storageProof)
	full := writePacket(p, height, nil).Blob(proof).Bytes()
	headLen := wire.NewWriter().Uint(p.Sequence).Str(p.SourceClient).Str(p.DestinationClient).Uint(p.TimeoutTimestamp).Uvarint(2).Len()
	heightAt := writePacket(p, height, nil).Len() - 16
	recv := func(bz []byte) func() { return func() { readRecv(bz) } }
	ack := func(bz []byte) func() { return func() { readAck(bz) } }
	short := wire.ErrShort.Error()

	cases := []struct {
		name, err string
		f         func()
	}{
		{"payload count beyond the message", errListLength.Error(), recv(
			wire.NewWriter().Uint(7).Str("a").Str("b").Uint(1).Uvarint(1000).Bytes())},
		{"ack count beyond the message", errListLength.Error(), ack(
			append(writePacket(p, height, nil).Bytes(), wire.NewWriter().Uvarint(1000).Bytes()...))},
		{"truncated inside a payload", short, recv(full[:headLen+5])},
		{"truncated inside the height", short, recv(full[:heightAt+11])},
		{"truncated inside the proof", short, recv(full[:len(full)-2])},
		// readPacket reports a truncated packet itself, before any later
		// read could.
		{"packet read alone, truncated inside a payload", short, func() { readPacket(wire.NewReader(full[:headLen+5])) }},
		{"packet read alone, truncated inside the height", short, func() { readPacket(wire.NewReader(full[:heightAt+11])) }},
		{"trailing bytes", errTrailing.Error(), recv(append(append([]byte{}, full...), 0))},
		{"not a membership proof", "wire: list longer than the remaining bytes", recv(
			writePacket(p, height, nil).Blob([]byte{5}).Bytes())},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			urequire.PanicsWithMessage(t, cur, tc.err, tc.f)
		})
	}
}

// Vectors encoded by the relayers themselves: the packet of testPacket, proof
// height {0, 1234}, the proof {accountProof, storageProof}, and for the
// acknowledgement the app acknowledgements {0x01, "ack-2"}. Produced by
// gno-eth-ibc relayer/ethgno.EncodePacketMsg (Go, at gno-eth-ibc 9cd0154),
// and byte for byte the same by allinbits/ibc-v2-ts-relayer
// src/clients/ethereum/wire.ts encodePacketMsg (TypeScript, at ecff6c0).
const (
	relayerRecvVector = "000000000000000708636c69656e742d300a657468657265756d2d31000000006904819802087472616e73666572087472616e736665720769637332302d311a6170706c69636174696f6e2f782d736f6c69646974792d61626904deadbeef06706f72742d6106706f72742d62027632106170706c69636174696f6e2f6a736f6e077b226b223a317d000000000000000000000000000004d20b020301020301040102aabb"
	relayerAckVector  = "000000000000000708636c69656e742d300a657468657265756d2d31000000006904819802087472616e73666572087472616e736665720769637332302d311a6170706c69636174696f6e2f782d736f6c69646974792d61626904deadbeef06706f72742d6106706f72742d62027632106170706c69636174696f6e2f6a736f6e077b226b223a317d000000000000000000000000000004d20201010561636b2d320b020301020301040102aabb"
)

// The relayers' encoding is what ethrelay reads.
func TestRelayerVectors(t *testing.T) {
	bz, err := hex.DecodeString(relayerRecvVector)
	urequire.NoError(t, err)
	p, h, proof := readRecv(bz)
	assertPacket(t, testPacket(), p)
	urequire.Equal(t, uint64(0), h.RevisionNumber)
	urequire.Equal(t, uint64(1234), h.RevisionHeight)
	assertProof(t, proof)
	urequire.True(t, bytes.Equal(bz, writePacket(testPacket(), types.NewHeight(0, 1234), nil).Blob(encodeProof(accountProof, storageProof)).Bytes()))

	bz, err = hex.DecodeString(relayerAckVector)
	urequire.NoError(t, err)
	p, h, acks, proof := readAck(bz)
	assertPacket(t, testPacket(), p)
	urequire.Equal(t, uint64(1234), h.RevisionHeight)
	assertBlobs(t, [][]byte{{1}, []byte("ack-2")}, acks)
	assertProof(t, proof)
}
