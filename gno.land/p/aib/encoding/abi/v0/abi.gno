// Package abi is a small Solidity ABI encoder: abi.encode of values built from
// the constructors below, as Solidity's abi.encode and abi.decode see them
// (the "Formal Specification of the Encoding" of the Solidity ABI spec).
//
// Supported types: every static 32-byte type (uintN, intN for non-negative
// values, address, bool, bytes32 and bytesN), the dynamic string and bytes,
// tuples (static or dynamic) and dynamic arrays T[]. Fixed-size arrays T[k] are
// not supported: they encode as a tuple of k elements of T, so Tuple serves.
//
//	params := abi.Encode(abi.Uint64(1), abi.String("client-0"))
//	// == abi.encode(uint8(1), "client-0") in Solidity
//
// Encode(vs...) is abi.encode(v1, ..., vn): the encoding of the tuple of the
// arguments, without an outer offset word. A Solidity contract reads it back
// with abi.decode(data, (T1, ..., Tn)).
package abi

import (
	"encoding/binary"
	"errors"
)

// Word is the ABI word size in bytes.
const Word = 32

type kind uint8

const (
	kindWord  kind = iota + 1 // a static 32-byte value
	kindBytes                 // string or bytes: dynamic
	kindTuple                 // dynamic iff a component is
	kindArray                 // T[]: always dynamic
)

// Value is one ABI value. Build it with the constructors; the zero Value is
// invalid and Encode panics on it.
type Value struct {
	kind  kind
	word  [Word]byte
	data  []byte
	elems []Value
}

// Uint64 is a uintN (N ≥ 8) or a non-negative intN holding v.
func Uint64(v uint64) Value {
	var w [Word]byte
	binary.BigEndian.PutUint64(w[Word-8:], v)
	return Value{kind: kindWord, word: w}
}

// Bool is a bool.
func Bool(b bool) Value {
	if b {
		return Uint64(1)
	}
	return Uint64(0)
}

// Address is an address: 20 bytes, left-padded with zeros.
func Address(a [20]byte) Value {
	var w [Word]byte
	copy(w[Word-20:], a[:])
	return Value{kind: kindWord, word: w}
}

// Bytes32 is a bytes32.
func Bytes32(b [Word]byte) Value {
	return Value{kind: kindWord, word: b}
}

// Uint256 is a uint256 given as its 32 big-endian bytes.
func Uint256(w [Word]byte) Value {
	return Value{kind: kindWord, word: w}
}

// Uint256Decimal is a uint256 given in decimal digits: no sign, no leading
// "+", no spaces, at least one digit; leading zeros are accepted. It errs when
// the number does not fit 256 bits.
func Uint256Decimal(s string) (Value, error) {
	w, err := DecimalWord(s)
	if err != nil {
		return Value{}, err
	}
	return Uint256(w), nil
}

// DecimalWord parses decimal digits into a big-endian 32-byte word.
func DecimalWord(s string) ([Word]byte, error) {
	var w [Word]byte
	if s == "" {
		return w, errors.New("abi: empty number")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return w, errors.New("abi: not a decimal number")
		}
		carry := uint(c - '0')
		for j := Word - 1; j >= 0; j-- {
			v := uint(w[j])*10 + carry
			w[j] = byte(v)
			carry = v >> 8
		}
		if carry != 0 {
			return w, errors.New("abi: number overflows uint256")
		}
	}
	return w, nil
}

// WordDecimal formats a big-endian 32-byte word in decimal digits.
func WordDecimal(w [Word]byte) string {
	n := w
	var digits []byte
	for {
		zero := true
		var rem uint
		for i := 0; i < Word; i++ {
			v := rem<<8 | uint(n[i])
			n[i] = byte(v / 10)
			rem = v % 10
			if n[i] != 0 {
				zero = false
			}
		}
		digits = append(digits, byte('0'+rem))
		if zero {
			break
		}
	}
	for i, j := 0, len(digits)-1; i < j; i, j = i+1, j-1 {
		digits[i], digits[j] = digits[j], digits[i]
	}
	return string(digits)
}

// String is a string (UTF-8 bytes, as Solidity keeps them).
func String(s string) Value {
	return Value{kind: kindBytes, data: []byte(s)}
}

// Bytes is a bytes. The slice is copied.
func Bytes(b []byte) Value {
	return Value{kind: kindBytes, data: append([]byte{}, b...)}
}

// Tuple is a tuple (a Solidity struct) of the components, in order.
func Tuple(components ...Value) Value {
	return Value{kind: kindTuple, elems: append([]Value{}, components...)}
}

// Array is a dynamic array T[] of the elements, which must all have the same
// ABI type; an empty array encodes as its length alone, whatever T is.
func Array(elems ...Value) Value {
	return Value{kind: kindArray, elems: append([]Value{}, elems...)}
}

// Dynamic reports whether the value's type is dynamic: string, bytes, any
// T[], and a tuple with a dynamic component.
func (v Value) Dynamic() bool {
	switch v.kind {
	case kindWord:
		return false
	case kindBytes, kindArray:
		return true
	case kindTuple:
		for _, e := range v.elems {
			if e.Dynamic() {
				return true
			}
		}
		return false
	}
	panic("abi: invalid value")
}

// Encode is abi.encode(vs...).
func Encode(vs ...Value) []byte {
	return encodeSeq(vs)
}

// uintWord is v as a big-endian ABI word.
func uintWord(v uint64) []byte {
	w := make([]byte, Word)
	binary.BigEndian.PutUint64(w[Word-8:], v)
	return w
}

// encode is enc(v) of the spec.
func encode(v Value) []byte {
	switch v.kind {
	case kindWord:
		w := v.word
		return w[:]
	case kindBytes:
		padded := (len(v.data) + Word - 1) / Word * Word
		out := uintWord(uint64(len(v.data)))
		body := make([]byte, padded)
		copy(body, v.data)
		return append(out, body...)
	case kindTuple:
		return encodeSeq(v.elems)
	case kindArray:
		return append(uintWord(uint64(len(v.elems))), encodeSeq(v.elems)...)
	}
	panic("abi: invalid value")
}

// encodeSeq encodes a tuple's components: the heads (a static component
// in place, the offset of a dynamic one, counted from the start of the
// heads), then the tails of the dynamic components in order.
func encodeSeq(vs []Value) []byte {
	encs := make([][]byte, len(vs))
	headLen := 0
	for i, v := range vs {
		encs[i] = encode(v)
		if v.Dynamic() {
			headLen += Word
		} else {
			headLen += len(encs[i])
		}
	}
	out := make([]byte, 0, headLen)
	tailOff := headLen
	for i, v := range vs {
		if v.Dynamic() {
			out = append(out, uintWord(uint64(tailOff))...)
			tailOff += len(encs[i])
		} else {
			out = append(out, encs[i]...)
		}
	}
	for i, v := range vs {
		if v.Dynamic() {
			out = append(out, encs[i]...)
		}
	}
	return out
}
