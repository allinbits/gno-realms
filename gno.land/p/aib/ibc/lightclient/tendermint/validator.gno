package tendermint

import (
	"bytes"
	"encoding/base64"

	"gno.land/p/aib/encoding/proto"
	"gno.land/p/aib/merkle"
)

type ValidatorSet struct {
	Validators       []*Validator
	Proposer         *Validator
	TotalVotingPower int64
}

func NewValset(vals ...*Validator) *ValidatorSet {
	var total int64
	for _, v := range vals {
		total += v.VotingPower
	}
	return &ValidatorSet{
		Validators:       vals,
		Proposer:         vals[0],
		TotalVotingPower: total,
	}
}

func (vals ValidatorSet) Hash() []byte {
	bzs := make([][]byte, len(vals.Validators))
	for i, val := range vals.Validators {
		bzs[i] = val.Bytes()
	}
	return merkle.HashFromByteSlices(bzs)
}

// GetByAddress returns an index of the validator with address and validator
// itself (copy) if found. Otherwise, -1 and nil are returned.
func (vals *ValidatorSet) GetByAddress(address []byte) (index int32, val *Validator) {
	for idx, val := range vals.Validators {
		if bytes.Equal(val.Address, address) {
			return int32(idx), val
		}
	}
	return -1, nil
}

type Validator struct {
	Address          []byte
	PubKey           []byte
	VotingPower      int64
	ProposerPriority int64
}

func NewValidator(addr, pubkey string, vp int64) *Validator {
	addrBz, err := base64.StdEncoding.DecodeString(addr)
	if err != nil {
		panic(err)
	}
	pubkeyBz, err := base64.StdEncoding.DecodeString(pubkey)
	if err != nil {
		panic(err)
	}
	return &Validator{
		Address:     addrBz,
		PubKey:      pubkeyBz,
		VotingPower: vp,
	}
}

// Bytes computes the unique encoding of a validator with a given voting power.
// These are the bytes that gets hashed in consensus. It excludes address as
// its redundant with the pubkey.This also excludes ProposerPriority which
// changes every round.
// Proto ref: https://buf.build/tendermint/tendermint/docs/main:tendermint.types#tendermint.types.SimpleValidator
func (v Validator) Bytes() (bz []byte) {
	pkBz := proto.AppendLengthDelimited(nil, 1, v.PubKey)
	bz = proto.AppendLengthDelimited(bz, 1, pkBz)
	bz = proto.AppendVarint(bz, 2, uint64(v.VotingPower))
	return
}
