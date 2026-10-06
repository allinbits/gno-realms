package merkle

import (
	"crypto/sha256"
)

// HashFromByteSlices computes a Merkle tree where the leaves are the byte
// slice, in the provided order. It follows RFC-6962.
func HashFromByteSlices(items [][]byte) []byte {
	switch len(items) {
	case 0:
		return emptyHash()
	case 1:
		return leafHash(items[0])
	default:
		// Find the split point (largest power of 2 <= len(items)).
		length := len(items)
		var k int
		for k = 1; k < length; k <<= 1 {
		}
		k >>= 1

		left := HashFromByteSlices(items[:k])
		right := HashFromByteSlices(items[k:])
		return innerHash(left, right)
	}
}

var (
	leafPrefix  = []byte{0x00}
	innerPrefix = []byte{0x01}
)

// emptyHash returns sha256(<empty>)
func emptyHash() []byte {
	bz := sha256.Sum256([]byte{})
	return bz[:]
}

// leafHash returns sha256(0x00 || leaf)
func leafHash(leaf []byte) []byte {
	bz := sha256.Sum256(append(leafPrefix, leaf...))
	return bz[:]
}

// innerHash returns sha256(0x01 || left || right)
func innerHash(left, right []byte) []byte {
	bz := sha256.Sum256(append(innerPrefix, append(left, right...)...))
	return bz[:]
}
