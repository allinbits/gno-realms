package tendermint

import (
	"bytes"
	"encoding/base64"
	"errors"
	"math"

	"gno.land/p/aib/encoding/proto/v0"
	"gno.land/p/aib/merkle/v0"
	"gno.land/p/nt/ufmt/v0"
)

// MaxTotalVotingPower is the largest total voting power a validator set may
// have, as in cometbft. It leaves headroom for the threshold multiplications.
const MaxTotalVotingPower = int64(math.MaxInt64) / 8

// ValidatorSet has no total voting power field: a relayer-supplied total
// isn't covered by Hash(), so it is always recomputed from Validators (see
// computeTotalVotingPower), as cometbft does in ValidatorSetFromProto.
type ValidatorSet struct {
	Validators []*Validator
	Proposer   *Validator
}

func NewValset(vals ...*Validator) *ValidatorSet {
	return &ValidatorSet{
		Validators: vals,
		Proposer:   vals[0],
	}
}

func (vals ValidatorSet) Hash() []byte {
	bzs := make([][]byte, len(vals.Validators))
	for i, val := range vals.Validators {
		bzs[i] = val.Bytes()
	}
	return merkle.HashFromByteSlices(bzs)
}

// computeTotalVotingPower returns the sum of the validators' voting powers.
// It fails if a validator has a negative voting power or if the total exceeds
// MaxTotalVotingPower.
func (vals ValidatorSet) computeTotalVotingPower() (int64, error) {
	var total int64
	for i, val := range vals.Validators {
		if val == nil {
			return 0, ufmt.Errorf("validator #%d is nil", i)
		}
		if val.VotingPower < 0 {
			return 0, ufmt.Errorf("validator #%d has negative voting power %d", i, val.VotingPower)
		}
		if val.VotingPower > MaxTotalVotingPower-total {
			return 0, ufmt.Errorf("total voting power exceeds maximum %d", MaxTotalVotingPower)
		}
		total += val.VotingPower
	}
	return total, nil
}

// votingPowerThreshold returns total*numerator/denominator, the voting power a
// commit by vals must exceed, where total is recomputed from the validators.
func votingPowerThreshold(vals *ValidatorSet, numerator, denominator uint64) (int64, error) {
	total, err := vals.computeTotalVotingPower()
	if err != nil {
		return 0, err
	}
	if denominator == 0 || denominator > math.MaxInt64 {
		return 0, ufmt.Errorf("invalid voting power threshold denominator %d", denominator)
	}
	if total == 0 {
		return 0, nil
	}
	if numerator > uint64(math.MaxInt64/total) {
		return 0, errors.New("voting power threshold overflows")
	}
	return total * int64(numerator) / int64(denominator), nil
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
