package proto

import (
	"testing"

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
