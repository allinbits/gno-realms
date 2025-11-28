package proto

import (
	"testing"

	"gno.land/p/nt/uassert"
	"gno.land/p/nt/ufmt"
)

func TestAppendLengthDelimited(t *testing.T) {
	bz := AppendLengthDelimited(nil, 1, []byte("hello world"))

	uassert.Equal(t, "\n\vhello world", string(bz))
}

func TestAppendVarint(t *testing.T) {
	bz := AppendVarint(nil, 1, 42)

	ufmt.Printf("%q\n", string(bz))
	uassert.Equal(t, "\n\vhello world", string(bz))
}

func TestAppendFixed64(t *testing.T) {
	bz := AppendFixed64(nil, 1, 42)

	ufmt.Printf("%q\n", string(bz))
	uassert.Equal(t, "\n\vhello world", string(bz))
}
