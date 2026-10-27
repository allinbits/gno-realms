// Package abi encodes ICS20 FungibleTokenPacketData the way the Solidity
// ICS20 application of cosmos/solidity-ibc-eureka does: as
// abi.encode(FungibleTokenPacketData{string denom; string sender;
// string receiver; uint256 amount; string memo}), under the payload encoding
// "application/x-solidity-abi".
package abi

import (
	"errors"

	"gno.land/p/aib/ibc/ics20/v0"
)

// Encoding is the ICS20 payload encoding of Solidity ABI packet data.
const Encoding = "application/x-solidity-abi"

const word = 32

var errDecode = errors.New("abi: invalid FungibleTokenPacketData encoding")

// Marshal ABI-encodes data. The amount must be a decimal number below 2^256.
func Marshal(data ics20.FungibleTokenPacketData) ([]byte, error) {
	amount, err := decimalToUint256(data.Amount)
	if err != nil {
		return nil, err
	}
	strs := []string{data.Denom, data.Sender, data.Receiver, data.Memo}
	// Tuple head: denom, sender, receiver offsets, amount, memo offset.
	const headLen = 5 * word
	var tails [][]byte
	offsets := make([]uint64, len(strs))
	next := uint64(headLen)
	for i, s := range strs {
		offsets[i] = next
		t := encodeString(s)
		tails = append(tails, t)
		next += uint64(len(t))
	}
	out := uintWord(word) // offset of the tuple, which is dynamic
	out = append(out, uintWord(offsets[0])...)
	out = append(out, uintWord(offsets[1])...)
	out = append(out, uintWord(offsets[2])...)
	out = append(out, amount...)
	out = append(out, uintWord(offsets[3])...)
	for _, t := range tails {
		out = append(out, t...)
	}
	return out, nil
}

// Unmarshal decodes ABI-encoded packet data. Like Solidity's abi.decode it
// accepts any in-range offsets, and it rejects amounts that do not fit the
// decimal string ICS20 uses (none: every uint256 does).
func Unmarshal(bz []byte) (ics20.FungibleTokenPacketData, error) {
	var data ics20.FungibleTokenPacketData
	tupleOff, err := readUint(bz, 0)
	if err != nil {
		return data, err
	}
	tuple, err := slice(bz, tupleOff, uint64(len(bz))-tupleOff)
	if err != nil {
		return data, err
	}
	fields := make([]string, 4)
	for i, headIdx := range []uint64{0, 1, 2, 4} {
		off, err := readUint(tuple, headIdx*word)
		if err != nil {
			return data, err
		}
		s, err := readString(tuple, off)
		if err != nil {
			return data, err
		}
		fields[i] = s
	}
	amountWord, err := slice(tuple, 3*word, word)
	if err != nil {
		return data, err
	}
	data.Denom = fields[0]
	data.Sender = fields[1]
	data.Receiver = fields[2]
	data.Amount = uint256ToDecimal(amountWord)
	data.Memo = fields[3]
	return data, nil
}

func uintWord(v uint64) []byte {
	w := make([]byte, word)
	for i := 0; i < 8; i++ {
		w[word-1-i] = byte(v >> (8 * uint(i)))
	}
	return w
}

func encodeString(s string) []byte {
	padded := (len(s) + word - 1) / word * word
	out := uintWord(uint64(len(s)))
	body := make([]byte, padded)
	copy(body, s)
	return append(out, body...)
}

func slice(b []byte, off, n uint64) ([]byte, error) {
	if off > uint64(len(b)) || n > uint64(len(b))-off {
		return nil, errDecode
	}
	return b[off : off+n], nil
}

// readUint reads the word at off as a uint64; larger values are invalid
// offsets or lengths.
func readUint(b []byte, off uint64) (uint64, error) {
	w, err := slice(b, off, word)
	if err != nil {
		return 0, err
	}
	for _, c := range w[:word-8] {
		if c != 0 {
			return 0, errDecode
		}
	}
	var v uint64
	for _, c := range w[word-8:] {
		v = v<<8 | uint64(c)
	}
	return v, nil
}

func readString(tuple []byte, off uint64) (string, error) {
	n, err := readUint(tuple, off)
	if err != nil {
		return "", err
	}
	s, err := slice(tuple, off+word, n)
	if err != nil {
		return "", err
	}
	return string(s), nil
}

// decimalToUint256 parses a decimal string into a big-endian 32-byte word.
func decimalToUint256(s string) ([]byte, error) {
	if s == "" {
		return nil, errors.New("abi: empty amount")
	}
	w := make([]byte, word)
	for _, c := range []byte(s) {
		if c < '0' || c > '9' {
			return nil, errors.New("abi: amount is not a decimal number")
		}
		// w = w*10 + digit
		carry := uint(c - '0')
		for i := word - 1; i >= 0; i-- {
			v := uint(w[i])*10 + carry
			w[i] = byte(v)
			carry = v >> 8
		}
		if carry != 0 {
			return nil, errors.New("abi: amount overflows uint256")
		}
	}
	return w, nil
}

// uint256ToDecimal formats a big-endian word as a decimal string.
func uint256ToDecimal(w []byte) string {
	n := append([]byte{}, w...)
	var digits []byte
	for {
		zero := true
		var rem uint
		for i := range n {
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
