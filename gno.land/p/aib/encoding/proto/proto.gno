package proto

import (
	"encoding/binary"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

type WireType int

const (
	VARINT  WireType = 0 //	int32, int64, uint32, uint64, sint32, sint64, bool, enum
	FIXED64 WireType = 1 // fixed64, sfixed64, double
	LEN     WireType = 2 // string, bytes, embedded messages, packed repeated fields
	FIXED32 WireType = 5 //	fixed32, sfixed32, float
)

// AppendVarint appends a varint field.
func AppendVarint(buf []byte, fieldNum int, v uint64) []byte {
	if v == 0 {
		return buf
	}
	buf = AppendTag(buf, fieldNum, VARINT)
	return binary.AppendUvarint(buf, v)
}

// MarshalAny returns the wire encoding of a google.protobuf.Any message
// holding (typeURL, value). Used to match the cdc.MarshalInterface format
// produced by the Cosmos SDK proto codec when storing or verifying
// interface-typed messages (e.g. ClientState in the upgrade store).
func MarshalAny(typeURL string, value []byte) []byte {
	var bz []byte
	bz = AppendLengthDelimited(bz, 1, []byte(typeURL))
	bz = AppendLengthDelimited(bz, 2, value)
	return bz
}

// AppendPackedVarintInt32 appends a packed repeated int32 varint field.
// Negative values are sign-extended to 64 bits to match proto3 wire format.
// Returns buf unchanged when values is empty (proto3 default).
func AppendPackedVarintInt32(buf []byte, fieldNum int, values []int32) []byte {
	if len(values) == 0 {
		return buf
	}
	var packed []byte
	for _, v := range values {
		packed = binary.AppendUvarint(packed, uint64(int64(v)))
	}
	buf = AppendTag(buf, fieldNum, LEN)
	buf = binary.AppendUvarint(buf, uint64(len(packed)))
	return append(buf, packed...)
}

// AppendFixed64 appends a fixed 64-bit field.
func AppendFixed64(buf []byte, fieldNum int, v uint64) []byte {
	if v == 0 {
		return buf
	}
	buf = AppendTag(buf, fieldNum, FIXED64)
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], v)
	return append(buf, b[:]...)
}

// AppendLengthDelimited appends a length-delimited field. Returns buf
// unchanged when bz is empty (proto3 default for optional fields).
func AppendLengthDelimited(buf []byte, fieldNum int, bz []byte) []byte {
	if len(bz) == 0 {
		return buf
	}
	buf = AppendTag(buf, fieldNum, LEN)
	buf = binary.AppendUvarint(buf, uint64(len(bz)))
	return append(buf, bz...)
}

// AppendAlwaysLengthDelimited appends a length-delimited field, including
// when bz is empty (emits a length-0 value). Required to match the wire
// format produced by gogoproto for fields marked
// `[(gogoproto.nullable) = false]`, which always serialize even when their
// underlying message has no non-zero fields.
func AppendAlwaysLengthDelimited(buf []byte, fieldNum int, bz []byte) []byte {
	buf = AppendTag(buf, fieldNum, LEN)
	buf = binary.AppendUvarint(buf, uint64(len(bz)))
	return append(buf, bz...)
}

// TimeMarshal returns a proto marshalled time.
func TimeMarshal(t time.Time) []byte {
	var (
		buf     []byte
		seconds = t.Unix()
		nanos   = int32(t.Nanosecond())
	)
	// Field 1: seconds (int64 - varint)
	buf = AppendVarint(buf, 1, uint64(seconds))
	// Field 2: nanos (int32 - varint)
	buf = AppendVarint(buf, 2, uint64(nanos))
	return buf
}

// AppendTime appends a google.protobuf.Timestamp field.
func AppendTime(buf []byte, fieldNum int, t time.Time) []byte {
	return AppendLengthDelimited(buf, fieldNum, TimeMarshal(t))
}

// AppendTag appends a protobuf tag (field number and wire type)
func AppendTag(buf []byte, fieldNum int, wireType WireType) []byte {
	tag := (fieldNum << 3) | int(wireType)
	return binary.AppendUvarint(buf, uint64(tag))
}

// DecodeVarint reads a varint from the byte slice and returns the value and new position
func DecodeVarint(buf []byte, pos int) (uint64, int, error) {
	var result uint64
	var shift uint
	for {
		if pos >= len(buf) {
			return 0, pos, ufmt.Errorf("buffer underflow while reading varint")
		}
		b := buf[pos]
		pos++
		result |= uint64(b&0x7F) << shift
		if b&0x80 == 0 {
			break
		}
		shift += 7
	}
	return result, pos, nil
}

// DecodeString reads a string (length-prefixed) from the byte slice
func DecodeString(buf []byte, pos int) (string, int, error) {
	length, newPos, err := DecodeVarint(buf, pos)
	if err != nil {
		return "", newPos, err
	}
	pos = newPos

	if pos+int(length) > len(buf) {
		return "", pos, ufmt.Errorf("buffer underflow while reading string")
	}

	str := string(buf[pos : pos+int(length)])
	return str, pos + int(length), nil
}
