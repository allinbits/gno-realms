package ics23

import (
	"encoding/binary"
	"errors"

	"gno.land/p/aib/encoding/proto/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The protobuf encoding of an IBC MerkleProof, as ibc-go and the
// counterparty's ABCI query produce it:
//
//	ibc.core.commitment.v2.MerkleProof { repeated CommitmentProof proofs = 1; }
//	CommitmentProof   { oneof proof { ExistenceProof exist = 1; NonExistenceProof nonexist = 2;
//	                    BatchProof batch = 3; CompressedBatchProof compressed = 4; } }
//	ExistenceProof    { bytes key = 1; bytes value = 2; LeafOp leaf = 3; repeated InnerOp path = 4; }
//	NonExistenceProof { bytes key = 1; ExistenceProof left = 2; ExistenceProof right = 3; }
//	LeafOp            { HashOp hash = 1; HashOp prehash_key = 2; HashOp prehash_value = 3;
//	                    LengthOp length = 4; bytes prefix = 5; }
//	InnerOp           { HashOp hash = 1; bytes prefix = 2; bytes suffix = 3; }
//
// The decoder reads untrusted relayer input. It skips unknown fields as
// protobuf does, but refuses a known field with the wrong wire type, a
// singular field set twice, more than one proof of the oneof, and batch
// proofs, which no IBC proof uses. Decoded byte fields share the input's
// backing array: the proofs are verified and dropped, never stored.

const (
	wireVarint  = 0
	wireFixed64 = 1
	wireLen     = 2
	wireFixed32 = 5

	maxFieldNumber = 1<<29 - 1
)

var errMalformed = errors.New("malformed merkle proof")

// MarshalMerkleProof returns the protobuf encoding of a MerkleProof made of
// proofs, which UnmarshalMerkleProof reads back.
func MarshalMerkleProof(proofs []CommitmentProof) []byte {
	var bz []byte
	for _, p := range proofs {
		bz = proto.AppendAlwaysLengthDelimited(bz, 1, marshalCommitmentProof(p))
	}
	return bz
}

// UnmarshalMerkleProof decodes the protobuf encoding of a MerkleProof into
// its commitment proofs, each a CommitmentProof_Exist or a
// CommitmentProof_Nonexist.
func UnmarshalMerkleProof(bz []byte) ([]CommitmentProof, error) {
	r := reader{buf: bz}
	var proofs []CommitmentProof
	for r.more() {
		num, wt := r.field()
		if r.err != nil {
			break
		}
		if num != 1 {
			r.skip(num, wt, 0)
			continue
		}
		if wt != wireLen {
			r.wrongType(num, wt)
			break
		}
		sub := r.bytes()
		if r.err != nil {
			break
		}
		p, err := unmarshalCommitmentProof(sub)
		if err != nil {
			return nil, err
		}
		proofs = append(proofs, p)
	}
	if r.err != nil {
		return nil, r.err
	}
	return proofs, nil
}

func marshalCommitmentProof(p CommitmentProof) []byte {
	if e := p.GetExist(); e != nil {
		return proto.AppendAlwaysLengthDelimited(nil, 1, marshalExistenceProof(e))
	}
	if n := p.GetNonexist(); n != nil {
		return proto.AppendAlwaysLengthDelimited(nil, 2, marshalNonExistenceProof(n))
	}
	return nil
}

func marshalExistenceProof(p *ExistenceProof) []byte {
	bz := proto.AppendLengthDelimited(nil, 1, p.Key)
	bz = proto.AppendLengthDelimited(bz, 2, p.Value)
	if p.Leaf != nil {
		bz = proto.AppendAlwaysLengthDelimited(bz, 3, marshalLeafOp(p.Leaf))
	}
	for _, op := range p.Path {
		if op != nil {
			bz = proto.AppendAlwaysLengthDelimited(bz, 4, marshalInnerOp(op))
		}
	}
	return bz
}

func marshalNonExistenceProof(p *NonExistenceProof) []byte {
	bz := proto.AppendLengthDelimited(nil, 1, p.Key)
	if p.Left != nil {
		bz = proto.AppendAlwaysLengthDelimited(bz, 2, marshalExistenceProof(p.Left))
	}
	if p.Right != nil {
		bz = proto.AppendAlwaysLengthDelimited(bz, 3, marshalExistenceProof(p.Right))
	}
	return bz
}

func marshalLeafOp(op *LeafOp) []byte {
	bz := appendEnum(nil, 1, int32(op.Hash))
	bz = appendEnum(bz, 2, int32(op.PrehashKey))
	bz = appendEnum(bz, 3, int32(op.PrehashValue))
	bz = appendEnum(bz, 4, int32(op.Length))
	return proto.AppendLengthDelimited(bz, 5, op.Prefix)
}

func marshalInnerOp(op *InnerOp) []byte {
	bz := appendEnum(nil, 1, int32(op.Hash))
	bz = proto.AppendLengthDelimited(bz, 2, op.Prefix)
	return proto.AppendLengthDelimited(bz, 3, op.Suffix)
}

// appendEnum appends an enum field, sign-extending a negative value to 64
// bits as protobuf does.
func appendEnum(buf []byte, fieldNum int, v int32) []byte {
	return proto.AppendVarint(buf, fieldNum, uint64(int64(v)))
}

func unmarshalCommitmentProof(bz []byte) (CommitmentProof, error) {
	r := reader{buf: bz}
	var proof CommitmentProof
	for r.more() {
		num, wt := r.field()
		switch {
		case r.err != nil:
		case num > 4:
			r.skip(num, wt, 4)
		case wt != wireLen:
			r.wrongType(num, wt)
		case num > 2:
			r.fail(errors.New("batch commitment proofs are not supported"))
		case proof != nil:
			r.fail(ufmt.Errorf("%v: commitment proof sets more than one proof", errMalformed))
		case num == 1:
			sub := r.bytes()
			if r.err != nil {
				break
			}
			p, err := unmarshalExistenceProof(sub)
			if err != nil {
				return nil, err
			}
			proof = CommitmentProof_Exist{Exist: p}
		default:
			sub := r.bytes()
			if r.err != nil {
				break
			}
			p, err := unmarshalNonExistenceProof(sub)
			if err != nil {
				return nil, err
			}
			proof = CommitmentProof_Nonexist{Nonexist: p}
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	if proof == nil {
		return nil, ufmt.Errorf("%v: empty commitment proof", errMalformed)
	}
	return proof, nil
}

func unmarshalExistenceProof(bz []byte) (*ExistenceProof, error) {
	r := reader{buf: bz}
	p := &ExistenceProof{}
	for r.more() {
		num, wt := r.field()
		switch {
		case r.err != nil:
		case num > 4:
			r.skip(num, wt, 4)
		case wt != wireLen:
			r.wrongType(num, wt)
		case num == 4:
			sub := r.bytes()
			if r.err != nil {
				break
			}
			op, err := unmarshalInnerOp(sub)
			if err != nil {
				return nil, err
			}
			p.Path = append(p.Path, op)
		case !r.once(num):
		case num == 1:
			p.Key = r.bytes()
		case num == 2:
			p.Value = r.bytes()
		default:
			sub := r.bytes()
			if r.err != nil {
				break
			}
			leaf, err := unmarshalLeafOp(sub)
			if err != nil {
				return nil, err
			}
			p.Leaf = leaf
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return p, nil
}

func unmarshalNonExistenceProof(bz []byte) (*NonExistenceProof, error) {
	r := reader{buf: bz}
	p := &NonExistenceProof{}
	for r.more() {
		num, wt := r.field()
		switch {
		case r.err != nil:
		case num > 3:
			r.skip(num, wt, 3)
		case wt != wireLen:
			r.wrongType(num, wt)
		case !r.once(num):
		case num == 1:
			p.Key = r.bytes()
		default:
			sub := r.bytes()
			if r.err != nil {
				break
			}
			ep, err := unmarshalExistenceProof(sub)
			if err != nil {
				return nil, err
			}
			if num == 2 {
				p.Left = ep
			} else {
				p.Right = ep
			}
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return p, nil
}

func unmarshalLeafOp(bz []byte) (*LeafOp, error) {
	r := reader{buf: bz}
	op := &LeafOp{}
	for r.more() {
		num, wt := r.field()
		switch {
		case r.err != nil:
		case num > 5:
			r.skip(num, wt, 5)
		case num == 5 && wt != wireLen, num < 5 && wt != wireVarint:
			r.wrongType(num, wt)
		case !r.once(num):
		case num == 1:
			op.Hash = HashOp(r.enum())
		case num == 2:
			op.PrehashKey = HashOp(r.enum())
		case num == 3:
			op.PrehashValue = HashOp(r.enum())
		case num == 4:
			op.Length = LengthOp(r.enum())
		default:
			op.Prefix = r.bytes()
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return op, nil
}

func unmarshalInnerOp(bz []byte) (*InnerOp, error) {
	r := reader{buf: bz}
	op := &InnerOp{}
	for r.more() {
		num, wt := r.field()
		switch {
		case r.err != nil:
		case num > 3:
			r.skip(num, wt, 3)
		case num == 1 && wt != wireVarint, num > 1 && wt != wireLen:
			r.wrongType(num, wt)
		case !r.once(num):
		case num == 1:
			op.Hash = HashOp(r.enum())
		case num == 2:
			op.Prefix = r.bytes()
		default:
			op.Suffix = r.bytes()
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return op, nil
}

// reader reads the fields of one protobuf message. The first error sticks
// and ends the message.
type reader struct {
	buf  []byte
	seen uint32 // the singular fields read so far, by number (all below 32)
	err  error
}

func (r *reader) more() bool { return r.err == nil && len(r.buf) > 0 }

func (r *reader) fail(err error) {
	if r.err == nil {
		r.err = err
	}
	r.buf = nil
}

func (r *reader) wrongType(num, wt int) {
	r.fail(ufmt.Errorf("%v: field %d has wire type %d", errMalformed, num, wt))
}

// once records singular field num, refusing it if it was already read.
func (r *reader) once(num int) bool {
	bit := uint32(1) << uint(num)
	if r.seen&bit != 0 {
		r.fail(ufmt.Errorf("%v: field %d is set twice", errMalformed, num))
		return false
	}
	r.seen |= bit
	return true
}

func (r *reader) varint() uint64 {
	v, n := binary.Uvarint(r.buf)
	if n <= 0 {
		r.fail(ufmt.Errorf("%v: bad varint", errMalformed))
		return 0
	}
	r.buf = r.buf[n:]
	return v
}

// field reads a field tag: its number and wire type.
func (r *reader) field() (int, int) {
	tag := r.varint()
	if r.err != nil {
		return 0, 0
	}
	num := tag >> 3
	if num == 0 || num > maxFieldNumber {
		r.fail(ufmt.Errorf("%v: bad field number", errMalformed))
		return 0, 0
	}
	return int(num), int(tag & 7)
}

// enum reads an enum value, which protobuf encodes as an int32.
func (r *reader) enum() int32 {
	v := int64(r.varint())
	if v < -1<<31 || v > 1<<31-1 {
		r.fail(ufmt.Errorf("%v: enum value out of range", errMalformed))
		return 0
	}
	return int32(v)
}

// bytes reads a length-delimited value.
func (r *reader) bytes() []byte {
	n := r.varint()
	if r.err != nil {
		return nil
	}
	if n > uint64(len(r.buf)) {
		r.fail(ufmt.Errorf("%v: length %d beyond the message", errMalformed, n))
		return nil
	}
	b := r.buf[:n:n]
	r.buf = r.buf[n:]
	return b
}

// skip skips the value of unknown field num, refusing a field the message
// defines (known is its highest number) and the deprecated group types.
func (r *reader) skip(num, wt, known int) {
	if num <= known {
		r.wrongType(num, wt)
		return
	}
	switch wt {
	case wireVarint:
		r.varint()
	case wireFixed64:
		r.take(8)
	case wireLen:
		r.bytes()
	case wireFixed32:
		r.take(4)
	default:
		r.wrongType(num, wt)
	}
}

func (r *reader) take(n int) {
	if n > len(r.buf) {
		r.fail(ufmt.Errorf("%v: truncated field", errMalformed))
		return
	}
	r.buf = r.buf[n:]
}
