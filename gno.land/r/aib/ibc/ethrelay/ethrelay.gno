// Package ethrelay is the MsgCall entry point for relaying between gno.land
// and Ethereum. Each function takes its message as a []byte argument in the
// wire format (gno.land/p/clockwork/wire), which the VM base64-decodes
// natively, decodes it and forwards it to the IBC core. Relaying through
// MsgRun instead would charge preprocessing gas for every byte of the
// message rendered as Gno source.
//
// The core authorizes relayers by the transaction signer, which this realm
// does not change; it adds no authority of its own.
//
// Packet messages (RecvPacket, Acknowledgement, Timeout) are, in order:
//
//	Uint sequence, Str source_client, Str destination_client, Uint timeout,
//	list<Payload>, Uint proof_revision_number, Uint proof_revision_height,
//	[Acknowledgement only: list<blob> app_acknowledgements],
//	blob proof (a wire-encoded ethereum.MembershipProof)
//	Payload: Str source_port, Str destination_port, Str version, Str encoding, blob value
//
// where a list is a Uvarint count followed by its elements and a blob a
// Uvarint length followed by its bytes.
package ethrelay

import (
	"errors"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/clockwork/wire/v0"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient updates the Ethereum client clientID with a wire-encoded
// ethereum.Header.
func UpdateClient(cur realm, clientID string, header []byte) {
	h, err := ethereum.DecodeHeader(header)
	if err != nil {
		panic(err)
	}
	core.UpdateClient(cross(cur), clientID, h)
}

// SubmitMisbehaviour submits a wire-encoded ethereum.Misbehaviour.
func SubmitMisbehaviour(cur realm, clientID string, misbehaviour []byte) {
	m, err := ethereum.DecodeMisbehaviour(misbehaviour)
	if err != nil {
		panic(err)
	}
	core.UpdateClient(cross(cur), clientID, m)
}

// RecvPacket delivers a packet sent on Ethereum.
func RecvPacket(cur realm, msg []byte) types.ResponseResultType {
	d := wire.NewReader(msg)
	packet, height := readPacket(d)
	proof := readProof(d)
	return core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet: packet, ProofHeight: height, Ext: extproof.Proof{Data: proof},
	})
}

// Acknowledgement delivers the acknowledgement Ethereum wrote for a packet
// sent from gno.land.
func Acknowledgement(cur realm, msg []byte) types.ResponseResultType {
	d := wire.NewReader(msg)
	packet, height := readPacket(d)
	acks := readBlobs(d)
	proof := readProof(d)
	return core.Acknowledgement(cross(cur), types.MsgAcknowledgement{
		Packet:          packet,
		Acknowledgement: types.Acknowledgement{AppAcknowledgements: acks},
		ProofHeight:     height,
		Ext:             extproof.Proof{Data: proof},
	})
}

// Timeout times out a packet sent from gno.land that Ethereum never received.
func Timeout(cur realm, msg []byte) types.ResponseResultType {
	d := wire.NewReader(msg)
	packet, height := readPacket(d)
	proof := readProof(d)
	return core.Timeout(cross(cur), types.MsgTimeout{
		Packet: packet, ProofHeight: height, Ext: extproof.Proof{Data: proof},
	})
}

var (
	errListLength = errors.New("ethrelay: list longer than the message")
	errTrailing   = errors.New("ethrelay: trailing bytes")
)

// count reads a list length no larger than the remaining bytes, each element
// taking at least one.
func count(d *wire.Reader) int {
	n := d.Uvarint()
	if d.Err() != nil {
		panic(d.Err())
	}
	if n > uint64(d.Remaining()) {
		panic(errListLength)
	}
	return int(n)
}

func readBlobs(d *wire.Reader) [][]byte {
	out := make([][]byte, count(d))
	for i := range out {
		out[i] = d.Blob()
	}
	return out
}

func readPacket(d *wire.Reader) (types.Packet, types.Height) {
	p := types.Packet{
		Sequence:          d.Uint(),
		SourceClient:      d.Str(),
		DestinationClient: d.Str(),
		TimeoutTimestamp:  d.Uint(),
	}
	p.Payloads = make([]types.Payload, count(d))
	for i := range p.Payloads {
		p.Payloads[i] = types.Payload{
			SourcePort: d.Str(), DestinationPort: d.Str(), Version: d.Str(),
			Encoding: d.Str(), Value: d.Blob(),
		}
	}
	h := types.NewHeight(d.Uint(), d.Uint())
	if d.Err() != nil {
		panic(d.Err())
	}
	return p, h
}

// readProof reads the message's last field, the MembershipProof.
func readProof(d *wire.Reader) ethereum.MembershipProof {
	bz := d.Blob()
	if d.Err() != nil {
		panic(d.Err())
	}
	if !d.Done() {
		panic(errTrailing)
	}
	p, err := ethereum.DecodeMembershipProof(bz)
	if err != nil {
		panic(err)
	}
	return p
}
