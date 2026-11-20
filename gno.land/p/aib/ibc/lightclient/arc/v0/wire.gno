package arc

import (
	"errors"

	"gno.land/p/aib/encoding/wire/v0"
)

// Wire formats (gno.land/p/aib/encoding/wire: Uint = 8-byte BE, a blob and a
// list a Uvarint length or count then the elements):
//
//	Header: Uint trusted_height, Certificate, blob certified_header,
//	  blob block_header, list<blob> registry_proof, list<blob> set_nodes
//	Certificate: Uint height, Uint round, blob block_hash,
//	  list<blob address, blob signature>
//	Misbehaviour: blob header1, blob header2 (each a Header)
//	Creation: Uint chain_id, Uint trusting_period, Uint max_clock_drift,
//	  Uint trust_numerator, Uint trust_denominator, blob registry_address,
//	  blob registry_storage_location, blob ibc_contract_address,
//	  blob ibc_commitment_slot, blob block_header,
//	  list<blob> registry_proof, list<blob> set_nodes

var (
	errTrailing   = errors.New("wire: trailing bytes")
	errListLength = errors.New("wire: list longer than the remaining bytes")
	errRound      = errors.New("wire: round exceeds 32 bits")
)

type decoder struct {
	*wire.Reader
	err error
}

func newDecoder(bz []byte) *decoder { return &decoder{Reader: wire.NewReader(bz)} }

func (d *decoder) done() error {
	if d.err != nil {
		return d.err
	}
	if err := d.Err(); err != nil {
		return err
	}
	if !d.Done() {
		return errTrailing
	}
	return nil
}

// count reads a list length the remaining bytes can hold (every element
// takes at least one byte), before anything is allocated.
func (d *decoder) count() int {
	n := d.Uvarint()
	if d.Err() != nil || d.err != nil {
		return 0
	}
	if n > uint64(d.Remaining()) {
		d.err = errListLength
		return 0
	}
	return int(n)
}

func (d *decoder) blobs() [][]byte {
	out := make([][]byte, d.count())
	for i := range out {
		out[i] = d.Blob()
	}
	return out
}

func (d *decoder) header() *Header {
	h := &Header{TrustedHeight: d.Uint()}
	h.Certificate.Height = d.Uint()
	round := d.Uint()
	if round > 0xffffffff {
		d.err = errRound
	}
	h.Certificate.Round = uint32(round)
	h.Certificate.BlockHash = d.Blob()
	h.Certificate.Signatures = make([]CommitSignature, d.count())
	for i := range h.Certificate.Signatures {
		h.Certificate.Signatures[i] = CommitSignature{Address: d.Blob(), Signature: d.Blob()}
	}
	h.CertifiedHeader = d.Blob()
	h.BlockHeader = d.Blob()
	h.RegistryProof = d.blobs()
	h.SetNodes = d.blobs()
	return h
}

// DecodeHeader decodes a Header.
func DecodeHeader(bz []byte) (*Header, error) {
	d := newDecoder(bz)
	h := d.header()
	return h, d.done()
}

// DecodeMisbehaviour decodes a Misbehaviour.
func DecodeMisbehaviour(bz []byte) (*Misbehaviour, error) {
	d := newDecoder(bz)
	b1, b2 := d.Blob(), d.Blob()
	if err := d.done(); err != nil {
		return nil, err
	}
	h1, err := DecodeHeader(b1)
	if err != nil {
		return nil, err
	}
	h2, err := DecodeHeader(b2)
	if err != nil {
		return nil, err
	}
	return &Misbehaviour{Header1: h1, Header2: h2}, nil
}

// DecodeCreation decodes a client creation: the client state and the
// consensus state of its first trusted block, derived from that block's
// header and registry proofs (NewClientStates).
func DecodeCreation(bz []byte) (ClientState, ConsensusState, error) {
	d := newDecoder(bz)
	cs := ClientState{
		ChainID:                 d.Uint(),
		TrustingPeriod:          d.Uint(),
		MaxClockDrift:           d.Uint(),
		TrustLevel:              Fraction{Numerator: d.Uint(), Denominator: d.Uint()},
		RegistryAddress:         d.Blob(),
		RegistryStorageLocation: d.Blob(),
		IBCContractAddress:      d.Blob(),
		IBCCommitmentSlot:       d.Blob(),
	}
	exec := d.Blob()
	accountProof, nodes := d.blobs(), d.blobs()
	if err := d.done(); err != nil {
		return ClientState{}, ConsensusState{}, err
	}
	return NewClientStates(cs, exec, accountProof, nodes)
}

// EncodeHeader encodes h, for tests and relayers written in Gno.
func EncodeHeader(h *Header) []byte {
	w := wire.NewWriter()
	w.Uint(h.TrustedHeight).Uint(h.Certificate.Height).Uint(uint64(h.Certificate.Round)).Blob(h.Certificate.BlockHash)
	w.Uvarint(uint64(len(h.Certificate.Signatures)))
	for _, s := range h.Certificate.Signatures {
		w.Blob(s.Address).Blob(s.Signature)
	}
	w.Blob(h.CertifiedHeader).Blob(h.BlockHeader)
	for _, l := range [][][]byte{h.RegistryProof, h.SetNodes} {
		w.Uvarint(uint64(len(l)))
		for _, b := range l {
			w.Blob(b)
		}
	}
	return w.Bytes()
}
