package main

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

func hash2(a, b []byte) []byte {
	h := sha256.Sum256(append(append([]byte{}, a...), b...))
	return h[:]
}

func pubkeyBytes(v any) []byte {
	b, err := hex.DecodeString(strings.TrimPrefix(str(v), "0x"))
	if err != nil || len(b) != 48 {
		panic("bad pubkey")
	}
	return b
}

// pubkeysTree returns the layers of the SSZ tree of a sync committee's
// pubkeys vector, leaves first; len(pubkeys) is a power of two.
func pubkeysTree(pubkeys [][]byte) [][][]byte {
	layer := make([][]byte, len(pubkeys))
	for i, pk := range pubkeys {
		chunk := make([]byte, 32)
		copy(chunk, pk[32:])
		layer[i] = hash2(pk[:32], chunk)
	}
	layers := [][][]byte{layer}
	for len(layer) > 1 {
		next := make([][]byte, len(layer)/2)
		for i := range next {
			next[i] = hash2(layer[2*i], layer[2*i+1])
		}
		layers = append(layers, next)
		layer = next
	}
	return layers
}

// branch returns the sibling hashes from leaf i up to the root.
func branch(layers [][][]byte, i int) [][]byte {
	var out [][]byte
	for _, l := range layers[:len(layers)-1] {
		out = append(out, l[i^1])
		i /= 2
	}
	return out
}
