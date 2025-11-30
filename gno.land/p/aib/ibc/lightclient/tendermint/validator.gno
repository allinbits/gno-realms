package tendermint

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"

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

// Bytes returns a bytes representation of v, composed as follow:
// 32bytes: Pubkey
// varint: VotingPower
// TODO implement manual proto just like Vote ?
func (v Validator) Bytes() (bz []byte) {
	bz = append(bz, v.PubKey...)
	bz = binary.AppendVarint(bz, v.VotingPower)
	return
}
