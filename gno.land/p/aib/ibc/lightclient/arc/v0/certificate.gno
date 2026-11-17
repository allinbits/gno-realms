package arc

import (
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/bits"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Certificate is a Malachite commit certificate: the precommits of a round
// for the block whose hash is the certificate's value id (arc_getCertificate).
type Certificate struct {
	Height     uint64
	Round      uint32
	BlockHash  []byte
	Signatures []CommitSignature
}

// CommitSignature is one validator's precommit signature.
type CommitSignature struct {
	Address   []byte
	Signature []byte
}

func (c Certificate) validateBasic() error {
	switch {
	case c.Height == 0:
		return errors.New("certificate height must be positive")
	case len(c.BlockHash) != hashSize:
		return errors.New("certificate block hash must be 32 bytes")
	case len(c.Signatures) == 0:
		return errors.New("certificate has no signatures")
	case len(c.Signatures) > MaxValidators:
		return ufmt.Errorf("certificate has more than %d signatures", MaxValidators)
	}
	for _, s := range c.Signatures {
		if len(s.Address) != addressSize || len(s.Signature) != sigSize {
			return errors.New("malformed commit signature")
		}
	}
	return nil
}

// precommitSignBytes is what a validator signs for a precommit: the SSZ
// encoding of arc-node's Vote without its extension (crates/types/src/vote.rs,
// to_sign_bytes), signed as is, with no hash, domain or chain id:
//
//	type (1 byte, Precommit = 1) | height (u64 LE) |
//	offset of round (u32 LE, 37) | offset of value (u32 LE, 42) |
//	validator address (20 bytes) |
//	round: Option<u32> union, 1 then u32 LE |
//	value: NilOrVal union, 1 then the 32-byte block hash
func precommitSignBytes(height uint64, round uint32, blockHash, address []byte) []byte {
	b := make([]byte, 0, 75)
	b = append(b, 1)
	b = binary.LittleEndian.AppendUint64(b, height)
	b = binary.LittleEndian.AppendUint32(b, 37)
	b = binary.LittleEndian.AppendUint32(b, 42)
	b = append(b, address...)
	b = append(b, 1)
	b = binary.LittleEndian.AppendUint32(b, round)
	b = append(b, 1)
	return append(b, blockHash...)
}

// addressOf is a validator's address: the first 20 bytes of the Keccak-256
// of its public key (arc-node crates/types/src/address.rs).
func addressOf(pubKey []byte) []byte {
	return ethereum.Keccak256(pubKey)[:addressSize]
}

// signedPower checks every signature of c by a member of vs and returns the
// power of those members. A signature by a non-member is skipped (it may be
// valid under the other set of a skipping check); a duplicate member or an
// invalid signature by a member fails the certificate, as Malachite's
// verify_commit_certificate does. checked holds the public keys whose
// signature already verified, so a validator in both sets of a skipping
// check is verified once.
func (c Certificate) signedPower(vs *ValidatorSet, checked map[string]bool) (uint64, error) {
	index := make(map[string]int, len(vs.Validators))
	for i, v := range vs.Validators {
		index[string(v.Address)] = i
	}
	seen := make(map[string]bool, len(c.Signatures))
	var power uint64
	for _, s := range c.Signatures {
		addr := string(s.Address)
		if seen[addr] {
			return 0, ufmt.Errorf("duplicate signature by %s", hex.EncodeToString(s.Address))
		}
		seen[addr] = true
		i, ok := index[addr]
		if !ok {
			continue
		}
		v := vs.Validators[i]
		key := string(v.PubKey) + string(s.Signature)
		if !checked[key] {
			if !ed25519.Verify(v.PubKey, precommitSignBytes(c.Height, c.Round, c.BlockHash, v.Address), s.Signature) {
				return 0, ufmt.Errorf("invalid signature by %s", hex.EncodeToString(s.Address))
			}
			checked[key] = true
		}
		power += v.Power
	}
	return power, nil
}

// verify requires more than 2/3 of signers' power to have signed c
// (Malachite's threshold: signed*3 > total*2) and, unless trusted is nil,
// more than level of trusted's power: Tendermint's skipping check, which
// binds a block whose signers the trusted set does not know to the trusted
// set. The trust check runs first: signers comes from the message.
func (c Certificate) verify(signers, trusted *ValidatorSet, level Fraction) error {
	checked := map[string]bool{}
	if trusted != nil {
		power, err := c.signedPower(trusted, checked)
		if err != nil {
			return err
		}
		if !mulGreater(power, level.Denominator, trusted.TotalPower, level.Numerator) {
			return ufmt.Errorf("not enough trusted voting power: %d of %d signed, need more than %d/%d",
				power, trusted.TotalPower, level.Numerator, level.Denominator)
		}
	}
	power, err := c.signedPower(signers, checked)
	if err != nil {
		return err
	}
	if power*3 <= signers.TotalPower*2 {
		return ufmt.Errorf("not enough voting power: %d of %d signed, need more than 2/3", power, signers.TotalPower)
	}
	return nil
}

// mulGreater reports whether a*b > c*d, in 128 bits.
func mulGreater(a, b, c, d uint64) bool {
	hi1, lo1 := bits.Mul64(a, b)
	hi2, lo2 := bits.Mul64(c, d)
	return hi1 > hi2 || hi1 == hi2 && lo1 > lo2
}
