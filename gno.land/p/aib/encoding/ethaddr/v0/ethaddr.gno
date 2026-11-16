// Package ethaddr reads and writes Ethereum addresses as people and tools
// write them: "0x" and 40 hex digits, all lower case, all upper case, or mixed
// case that must be the address's EIP-55 checksum.
//
// Ported from gnolang/bridges (branch ethereum-draft, commit a58efe81c9eb),
// ethereum/realm/hlmailbox/ethaddr.gno (ParseEthAddress, EthAddress, eip55),
// Copyright (C) 2026 NewTendermint, LLC, under the GNO Network General Public
// License. Changes: an address is 20 bytes here (IBC carries the receiver as a
// hex string, not Hyperlane's left-padded 32 bytes), so the 64-digit form is
// not accepted; Reserved is new.
package ethaddr

import (
	"crypto/keccak256"
	"encoding/hex"
	"errors"
)

// Address is an Ethereum address.
type Address [20]byte

// Parse reads "0x" and 40 hex digits: all lower case, all upper case, or mixed
// case equal to the EIP-55 checksum (a mixed-case address with one letter's
// case wrong is a typo the checksum caught, refused). Nothing else is
// accepted: no surrounding spaces, no missing "0x", no other length. The zero
// address parses; callers refuse it where they must.
func Parse(s string) (Address, error) {
	var out Address
	if len(s) != 42 || s[0] != '0' || s[1] != 'x' {
		return out, errors.New("not an Ethereum address: want 0x and 40 hex digits")
	}
	h := s[2:]
	b, err := hex.DecodeString(h)
	if err != nil || len(b) != 20 {
		return out, errors.New("not an Ethereum address: want 0x and 40 hex digits")
	}
	copy(out[:], b)
	if hasLetter(h, 'a', 'f') && hasLetter(h, 'A', 'F') && checksum(b) != h {
		return out, errors.New("not an Ethereum address: mixed case that is not its EIP-55 checksum")
	}
	return out, nil
}

// String is the address in its EIP-55 checksum case, with "0x".
func (a Address) String() string {
	return "0x" + checksum(a[:])
}

// Lower is the address in lower case, with "0x": the form denoms and
// comparisons use.
func (a Address) Lower() string {
	return "0x" + hex.EncodeToString(a[:])
}

// IsZero reports whether a is the zero address.
func (a Address) IsZero() bool {
	return a == Address{}
}

// Reserved reports whether a is at or below 0xffff: a precompile's address,
// or one the protocol reserves. Nothing sent there can be moved again.
func (a Address) Reserved() bool {
	for _, c := range a[:18] {
		if c != 0 {
			return false
		}
	}
	return true
}

// checksum is a 20-byte address's 40 hex digits in EIP-55 case: a letter is
// upper case where the matching nibble of keccak256 of the lower-case hex (as
// ASCII) is 8 or more.
func checksum(addr []byte) string {
	lower := hex.EncodeToString(addr)
	h := keccak256.Sum256([]byte(lower))
	out := []byte(lower)
	for i := 0; i < len(out); i++ {
		c := out[i]
		if c < 'a' || c > 'f' {
			continue
		}
		nib := h[i/2] >> 4
		if i%2 == 1 {
			nib = h[i/2] & 0x0f
		}
		if nib >= 8 {
			out[i] = c - 'a' + 'A'
		}
	}
	return string(out)
}

func hasLetter(s string, lo, hi byte) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= lo && s[i] <= hi {
			return true
		}
	}
	return false
}
