// Package abi encodes ICS20 FungibleTokenPacketData the way the Solidity
// ICS20 application of cosmos/solidity-ibc-eureka does: as
// abi.encode(FungibleTokenPacketData{string denom; string sender;
// string receiver; uint256 amount; string memo}), under the payload encoding
// "application/x-solidity-abi".
package abi

import (
	"errors"

	abienc "gno.land/p/aib/encoding/abi/v0"
	"gno.land/p/aib/ibc/ics20/v0"
)

// Encoding is the ICS20 payload encoding of Solidity ABI packet data.
const Encoding = "application/x-solidity-abi"

const word = abienc.Word

// MaxAmount is the largest amount Ethereum's transfer app takes on a send or
// a receive, 2^96 - 1 (gno-eth-ibc GnoICS20Transfer: ICS20InvalidAmount above
// it; ADR pr6375 E6, §7.2). A gno.land send above it would only come back
// refused, and a receive above it can only be a forgery, so the transfer app
// refuses both before any state change.
const MaxAmount uint256 = 1<<96 - 1

var errDecode = errors.New("abi: invalid FungibleTokenPacketData encoding")

// Marshal ABI-encodes data. The amount must be a decimal number below 2^256.
func Marshal(data ics20.FungibleTokenPacketData) ([]byte, error) {
	amount, err := abienc.Uint256Decimal(data.Amount)
	if err != nil {
		return nil, err
	}
	return abienc.Encode(abienc.Tuple(abienc.String(data.Denom), abienc.String(data.Sender), abienc.String(data.Receiver), amount, abienc.String(data.Memo))), nil
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
	var amount [word]byte
	copy(amount[:], amountWord)
	data.Amount = abienc.WordDecimal(amount)
	data.Memo = fields[3]
	return data, nil
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
