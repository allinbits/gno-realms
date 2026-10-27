package ethereum

import (
	"bytes"
	"testing"

	"gno.land/p/nt/urequire/v0"
)

// Test RLP and hex-prefix encoders, for building tries by hand.

func rlpStr(b []byte) []byte {
	switch {
	case len(b) == 1 && b[0] < 0x80:
		return []byte{b[0]}
	case len(b) < 56:
		return append([]byte{0x80 + byte(len(b))}, b...)
	}
	return append([]byte{0xb8, byte(len(b))}, b...)
}

func rlpL(items ...[]byte) []byte {
	var p []byte
	for _, it := range items {
		p = append(p, it...)
	}
	if len(p) < 56 {
		return append([]byte{0xc0 + byte(len(p))}, p...)
	}
	return append([]byte{0xf8, byte(len(p))}, p...)
}

// compact is the hex-prefix encoding of nibbles.
func compact(nibbles []byte, leaf bool) []byte {
	flag := byte(0)
	if leaf {
		flag = 2
	}
	var out []byte
	if len(nibbles)%2 == 1 {
		out = append(out, (flag+1)<<4|nibbles[0])
		nibbles = nibbles[1:]
	} else {
		out = append(out, flag<<4)
	}
	for i := 0; i < len(nibbles); i += 2 {
		out = append(out, nibbles[i]<<4|nibbles[i+1])
	}
	return out
}

func leafNode(path []byte, value []byte) []byte {
	return rlpL(rlpStr(compact(path, true)), rlpStr(rlpStr(value)))
}

// A leaf answers only for its own key: another key of the same length is
// absent, not given the leaf's value.
func TestMPTLeafPathDivergence(t *testing.T) {
	a, b := []byte("slot a"), []byte("slot b")
	leaf := leafNode(toNibbles(keccak(a)), []byte{0x2a})
	root := keccak(leaf)
	v, err := storageValue(root, a, [][]byte{leaf})
	urequire.NoError(t, err)
	urequire.Equal(t, byte(0x2a), v[31])
	v, err = storageValue(root, b, [][]byte{leaf})
	urequire.NoError(t, err)
	urequire.True(t, bytes.Equal(v, make([]byte, 32)), "another key is absent")
}

// An extension answers only for keys under its path: a key that diverges
// there is absent, even when the branch below holds a leaf for its remaining
// path.
func TestMPTExtensionDivergence(t *testing.T) {
	a := []byte("slot a")
	ka := toNibbles(keccak(a))
	var b, kb []byte
	for i := 0; ; i++ {
		b = []byte{'b', byte(i)}
		kb = toNibbles(keccak(b))
		if kb[0] != ka[0] && kb[2] != ka[2] {
			break
		}
	}
	leafA, leafB := leafNode(ka[3:], []byte{1}), leafNode(kb[3:], []byte{2})
	elems := make([][]byte, 17)
	for i := range elems {
		elems[i] = rlpStr(nil)
	}
	elems[ka[2]] = rlpStr(keccak(leafA))
	elems[kb[2]] = rlpStr(keccak(leafB))
	branch := rlpL(elems...)
	ext := rlpL(rlpStr(compact(ka[:2], false)), rlpStr(keccak(branch)))
	proof := [][]byte{ext, branch, leafA, leafB}
	root := keccak(ext)

	v, err := storageValue(root, a, proof)
	urequire.NoError(t, err)
	urequire.Equal(t, byte(1), v[31])
	v, err = storageValue(root, b, proof)
	urequire.NoError(t, err)
	urequire.True(t, bytes.Equal(v, make([]byte, 32)), "a key diverging at the extension is absent")
}

// A stored value must be minimally encoded: no leading zero byte.
func TestStorageValueMinimal(t *testing.T) {
	a := []byte("slot a")
	leaf := leafNode(toNibbles(keccak(a)), []byte{0, 1})
	_, err := storageValue(keccak(leaf), a, [][]byte{leaf})
	urequire.Error(t, err)
}

// Non-canonical RLP and hex-prefix encodings are refused.
func TestNonCanonicalEncodings(t *testing.T) {
	for _, b := range [][]byte{
		{0x81, 0x05},             // a single byte below 0x80 in a string
		{0xb8, 0x01, 0x41},       // a long form for a short string
		{0xb9, 0x00, 0x40},       // a length with a leading zero
		{0x82, 0x01},             // shorter than its length
		{0x01, 0x02},             // trailing bytes
		{0xf8, 0x02, 0x01, 0x02}, // a long form for a short list
	} {
		_, err := rlpDecode(b)
		urequire.Error(t, err, "rlp")
	}
	// Flags above 3, and an even path whose first byte's low nibble is set.
	for _, b := range [][]byte{{}, {0x40}, {0x01}, {0x21}} {
		_, _, err := decodeCompactPath(b)
		urequire.Error(t, err, "hex prefix")
	}
	path, leaf, err := decodeCompactPath([]byte{0x31})
	urequire.NoError(t, err)
	urequire.True(t, leaf && len(path) == 1 && path[0] == 1, "an odd leaf path")
}
