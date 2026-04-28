package proto

import (
	"testing"
	"time"

	"gno.land/p/nt/uassert/v0"
)

func TestAppendLengthDelimited(t *testing.T) {
	bz := AppendLengthDelimited(nil, 1, []byte("hello world"))

	uassert.Equal(t, "\n\vhello world", string(bz))
}

func TestAppendVarint(t *testing.T) {
	bz := AppendVarint(nil, 1, 42)

	uassert.Equal(t, "\b*", string(bz))
}

func TestAppendFixed64(t *testing.T) {
	bz := AppendFixed64(nil, 1, 42)

	uassert.Equal(t, "\t*\x00\x00\x00\x00\x00\x00\x00", string(bz))
}

func TestTimeMarshal(t *testing.T) {
	t.Run("zero time omits both fields", func(t *testing.T) {
		// time.Time{} has Unix == -62135596800 (year 1) but the proto3
		// encoding here treats it as a varint: nonzero seconds, zero nanos.
		bz := TimeMarshal(time.Unix(0, 0).UTC())
		// seconds=0 omitted, nanos=0 omitted
		uassert.Equal(t, 0, len(bz))
	})

	t.Run("seconds only", func(t *testing.T) {
		bz := TimeMarshal(time.Unix(1700000000, 0).UTC())
		// field 1 seconds: tag 0x08, varint 1700000000 = 0x80 0xe2 0xcf 0xaa 0x06
		uassert.Equal(t, "\x08\x80\xe2\xcf\xaa\x06", string(bz))
	})

	t.Run("seconds and nanos", func(t *testing.T) {
		bz := TimeMarshal(time.Unix(1, 500).UTC())
		// field 1: 08 01 ; field 2: 10 f4 03 (nanos = 500)
		uassert.Equal(t, "\x08\x01\x10\xf4\x03", string(bz))
	})
}

func TestAppendTime(t *testing.T) {
	bz := AppendTime(nil, 3, time.Unix(1700000000, 0).UTC())
	// field 3 LEN: tag 0x1a, length 6, then TimeMarshal output
	uassert.Equal(t, "\x1a\x06\x08\x80\xe2\xcf\xaa\x06", string(bz))
}

func TestDurationMarshal(t *testing.T) {
	t.Run("zero duration encodes to nothing", func(t *testing.T) {
		bz := DurationMarshal(0)
		uassert.Equal(t, 0, len(bz))
	})

	t.Run("seconds only", func(t *testing.T) {
		bz := DurationMarshal(3 * time.Second)
		// field 1 seconds=3: tag 0x08, varint 0x03
		uassert.Equal(t, "\x08\x03", string(bz))
	})

	t.Run("nanos only", func(t *testing.T) {
		bz := DurationMarshal(500 * time.Nanosecond)
		// field 2 nanos=500: tag 0x10, varint 500 = 0xf4 0x03
		uassert.Equal(t, "\x10\xf4\x03", string(bz))
	})

	t.Run("seconds and nanos", func(t *testing.T) {
		bz := DurationMarshal(time.Second + 500*time.Nanosecond)
		uassert.Equal(t, "\x08\x01\x10\xf4\x03", string(bz))
	})

	t.Run("negative nanos are normalized into the next-lower second", func(t *testing.T) {
		// proto3 Duration requires nanos in [0, 1e9). For a negative
		// total duration we add a full second to nanos to get a
		// non-negative remainder.
		bz := DurationMarshal(-500 * time.Nanosecond)
		// seconds = 0 (omitted), nanos = 1e9 - 500 = 999_999_500
		// 999_999_500 in varint: 0x8c 0x90 0xeb 0xdc 0x03
		uassert.Equal(t, "\x10\x8c\x90\xeb\xdc\x03", string(bz))
	})
}

func TestAppendDuration(t *testing.T) {
	bz := AppendDuration(nil, 4, 3*time.Second)
	// field 4 LEN: tag 0x22, length 2, then DurationMarshal output
	uassert.Equal(t, "\x22\x02\x08\x03", string(bz))
}

func TestMarshalAny(t *testing.T) {
	t.Run("typeURL only, empty value", func(t *testing.T) {
		bz := MarshalAny("/x.Y", nil)
		// Field 1 (typeURL): tag 0x0a, len 4, "/x.Y"
		uassert.Equal(t, "\n\x04/x.Y", string(bz))
	})

	t.Run("typeURL and value", func(t *testing.T) {
		bz := MarshalAny("/x.Y", []byte{0xab, 0xcd})
		// Field 1 (typeURL): tag 0x0a, len 4, "/x.Y"
		// Field 2 (value):   tag 0x12, len 2, 0xab 0xcd
		uassert.Equal(t, "\n\x04/x.Y\x12\x02\xab\xcd", string(bz))
	})
}

func TestAppendPackedVarintInt32(t *testing.T) {
	t.Run("empty omits field", func(t *testing.T) {
		bz := AppendPackedVarintInt32(nil, 1, nil)
		uassert.Equal(t, 0, len(bz))

		bz = AppendPackedVarintInt32(nil, 1, []int32{})
		uassert.Equal(t, 0, len(bz))
	})

	t.Run("includes zero values inside the packed payload", func(t *testing.T) {
		bz := AppendPackedVarintInt32(nil, 1, []int32{0, 1})
		// tag = 1<<3 | 2 = 0x0a, length = 2, payload = 0x00 0x01
		uassert.Equal(t, "\n\x02\x00\x01", string(bz))
	})

	t.Run("multi-byte varints", func(t *testing.T) {
		bz := AppendPackedVarintInt32(nil, 2, []int32{300, 1})
		// tag = 2<<3 | 2 = 0x12; 300 = 0xac 0x02 (varint); 1 = 0x01
		// length = 3
		uassert.Equal(t, "\x12\x03\xac\x02\x01", string(bz))
	})

	t.Run("appends to existing buffer", func(t *testing.T) {
		bz := AppendPackedVarintInt32([]byte{0xff}, 1, []int32{1})
		uassert.Equal(t, "\xff\n\x01\x01", string(bz))
	})
}
