package arc

import (
	"errors"

	"gno.land/p/nt/ufmt/v0"
)

// ClientType is the client type of the Arc light client; its client ids are
// "arc-N".
const ClientType = "arc"

const (
	hashSize    = 32
	addressSize = 20
	pubKeySize  = 32
	sigSize     = 64

	// MaxValidators bounds the active registrations the client reads from
	// the registry, and so the cost of an update. Arc's registry has no
	// bound: past this many the client stops at the next set change.
	MaxValidators = 256

	// MaxClockDrift and TrustingPeriod bound the client's configuration, in
	// seconds, so that now()+MaxClockDrift cannot wrap.
	maxClockDrift  = 3600
	maxTrustPeriod = 365 * 24 * 3600
)

// RegistryAddress is the address of Arc's ValidatorRegistry proxy, whose
// active registrations the consensus layer reads at every height.
var RegistryAddress = []byte{
	0x36, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02,
}

// RegistryStorageLocation is the ERC-7201 base slot of the registry's
// storage: keccak256(abi.encode(uint256(keccak256("arc.storage.ValidatorRegistry")) - 1)) & ~0xff.
var RegistryStorageLocation = []byte{
	0xb5, 0x8d, 0xa0, 0xdc, 0xe0, 0x33, 0x16, 0x99, 0x2f, 0xae, 0xa3, 0xe1, 0x2c, 0x60, 0x70, 0x5b,
	0x8a, 0xc0, 0x5a, 0x30, 0x9e, 0x27, 0xe3, 0xbc, 0x84, 0x21, 0xe5, 0xb2, 0x71, 0xc9, 0xd2, 0x00,
}

// Fraction is a trust level, numerator/denominator.
type Fraction struct {
	Numerator   uint64
	Denominator uint64
}

// ClientState is the Arc client's configuration and progress.
//
// Arc's votes sign no chain id: what pins the client to one Arc network is
// its trusted validator set, from creation on. ChainID is recorded for the
// route identity and for relayers, and verifies nothing.
type ClientState struct {
	// ChainID is the EVM chain id (5042002 on the testnet).
	ChainID      uint64
	LatestHeight uint64
	IsFrozen     bool
	// TrustingPeriod is how long, in seconds, the validator set of the
	// latest trusted block is trusted to sign a later block. Arc is
	// permissioned, with no unbonding or slashing: this bounds how long
	// rotated-out keys keep the client's trust when no update brings it
	// past the rotation, and should be short.
	TrustingPeriod uint64
	// MaxClockDrift bounds, in seconds, how far ahead of gno.land's clock a
	// block's timestamp may be. Arc's validators accept a proposer's
	// timestamp up to 30 seconds ahead of their clocks (skew_gate.rs), and
	// gno.land's block time trails real time: leave room for both. It is
	// block's timestamp may be.
	MaxClockDrift uint64
	// TrustLevel is the share of the trusted set's power that must sign a
	// block more than one height ahead whose validator set changed, as in
	// Tendermint's skipping verification: at least 1/3.
	TrustLevel Fraction
	// RegistryAddress and RegistryStorageLocation locate the validator
	// registry the consensus layer reads (RegistryAddress,
	// RegistryStorageLocation by default).
	RegistryAddress         []byte
	RegistryStorageLocation []byte
	// RegistryImplementation is the registry proxy's ERC-1967
	// implementation, read from its storage at creation. The client reads
	// the set by the layout of that implementation: a set read finding
	// another implementation is refused, and only a governed recovery (with
	// a client of a version that knows the new layout) moves past it.
	RegistryImplementation []byte
	// IBCContractAddress is the ICS26 router; IBCCommitmentSlot the slot of
	// its commitments mapping.
	IBCContractAddress []byte
	IBCCommitmentSlot  []byte
}

// ClientType implements lightclient.ClientState.
func (ClientState) ClientType() string { return ClientType }

// ValidateBasic implements lightclient.ClientState.
func (cs ClientState) ValidateBasic() error {
	switch {
	case cs.ChainID == 0:
		return errors.New("chain id must be positive")
	case cs.LatestHeight == 0:
		return errors.New("latest height must be positive")
	case cs.IsFrozen:
		return errors.New("cannot create a frozen client")
	case cs.TrustingPeriod == 0 || cs.TrustingPeriod > maxTrustPeriod:
		return ufmt.Errorf("trusting period must be within (0, %d] seconds", maxTrustPeriod)
	case cs.MaxClockDrift == 0 || cs.MaxClockDrift > maxClockDrift:
		return ufmt.Errorf("max clock drift must be within (0, %d] seconds", maxClockDrift)
	case cs.TrustLevel.Denominator == 0 || cs.TrustLevel.Denominator > 1<<32 ||
		cs.TrustLevel.Numerator >= cs.TrustLevel.Denominator || cs.TrustLevel.Numerator*3 < cs.TrustLevel.Denominator:
		// Below 1: the check is "more than" the level, which no set can
		// pass at 1.
		return ufmt.Errorf("trust level %d/%d must be within [1/3, 1)", cs.TrustLevel.Numerator, cs.TrustLevel.Denominator)
	case len(cs.RegistryImplementation) != addressSize || isZero(cs.RegistryImplementation):
		return errors.New("registry implementation must be a nonzero 20-byte address")
	case len(cs.RegistryAddress) != addressSize:
		return errors.New("registry address must be 20 bytes")
	case len(cs.RegistryStorageLocation) != hashSize:
		return errors.New("registry storage location must be 32 bytes")
	case len(cs.IBCContractAddress) != addressSize:
		return errors.New("ibc contract address must be 20 bytes")
	case len(cs.IBCCommitmentSlot) != hashSize:
		return errors.New("ibc commitment slot must be 32 bytes")
	}
	return nil
}

func (cs ClientState) clone() ClientState {
	cs.RegistryAddress = cloneBytes(cs.RegistryAddress)
	cs.RegistryStorageLocation = cloneBytes(cs.RegistryStorageLocation)
	cs.RegistryImplementation = cloneBytes(cs.RegistryImplementation)
	cs.IBCContractAddress = cloneBytes(cs.IBCContractAddress)
	cs.IBCCommitmentSlot = cloneBytes(cs.IBCCommitmentSlot)
	return cs
}

// ConsensusState is what the client trusts of one Arc block.
type ConsensusState struct {
	Height uint64
	// Timestamp is the block's timestamp, in seconds.
	Timestamp uint64
	BlockHash []byte
	StateRoot []byte
	// RegistryStorageRoot is the validator registry's storage root in the
	// block's state: when a later block's registry root equals it, the two
	// blocks' states hold the same validator set.
	RegistryStorageRoot []byte
	// NextValidators is the validator set the registry holds in the block's
	// state: the set that signs the next block (the consensus layer reads
	// the set for height H from the state after H-1).
	NextValidators *ValidatorSet
}

// ClientType implements lightclient.ConsensusState.
func (ConsensusState) ClientType() string { return ClientType }

// ValidateBasic implements lightclient.ConsensusState.
func (cs ConsensusState) ValidateBasic() error {
	switch {
	case cs.Height == 0:
		return errors.New("height must be positive")
	case len(cs.BlockHash) != hashSize:
		return errors.New("block hash must be 32 bytes")
	case len(cs.StateRoot) != hashSize:
		return errors.New("state root must be 32 bytes")
	case len(cs.RegistryStorageRoot) != hashSize:
		return errors.New("registry storage root must be 32 bytes")
	case cs.NextValidators == nil:
		return errors.New("next validators must be set")
	}
	return cs.NextValidators.validate()
}

// copyConsensusState is a deep copy of in, sharing no byte slice; the
// validator set is shared, as nothing writes to a set once built.
func copyConsensusState(in ConsensusState) ConsensusState {
	return ConsensusState{
		Height:              in.Height,
		Timestamp:           in.Timestamp,
		BlockHash:           cloneBytes(in.BlockHash),
		StateRoot:           cloneBytes(in.StateRoot),
		RegistryStorageRoot: cloneBytes(in.RegistryStorageRoot),
		NextValidators:      in.NextValidators,
	}
}

// Validator is one active registration with positive power.
type Validator struct {
	// Address is keccak256(PubKey)[:20], how a certificate names the
	// validator.
	Address []byte
	PubKey  []byte
	Power   uint64
}

// ValidatorSet is a validator set in the registry's order.
type ValidatorSet struct {
	Validators []Validator
	TotalPower uint64
}

// NewValidatorSet builds a set from public keys and powers, in order. Every
// key must be an Ed25519 point.
func NewValidatorSet(pubKeys [][]byte, powers []uint64) (*ValidatorSet, error) {
	if len(pubKeys) != len(powers) {
		return nil, errors.New("public keys and powers differ in length")
	}
	vs := &ValidatorSet{}
	for i, pk := range pubKeys {
		if err := vs.add(pk, powers[i]); err != nil {
			return nil, err
		}
	}
	return vs, vs.validate()
}

func (vs *ValidatorSet) add(pubKey []byte, power uint64) error {
	if len(vs.Validators) >= MaxValidators {
		return ufmt.Errorf("more than %d validators", MaxValidators)
	}
	if len(pubKey) != pubKeySize || !isEdwardsPoint(pubKey) {
		return errors.New("validator public key must be a 32-byte Ed25519 point")
	}
	if power == 0 {
		return errors.New("validator power must be positive")
	}
	if power > maxTotalPower || vs.TotalPower+power > maxTotalPower {
		return errors.New("total voting power overflows")
	}
	pk := cloneBytes(pubKey)
	addr := addressOf(pk)
	for _, v := range vs.Validators {
		if string(v.Address) == string(addr) {
			return errors.New("duplicate validator")
		}
	}
	vs.Validators = append(vs.Validators, Validator{Address: addr, PubKey: pk, Power: power})
	vs.TotalPower += power
	return nil
}

// maxTotalPower keeps power*3 from wrapping (the trust check multiplies in
// 128 bits). Arc's powers are uint64 and its own sum panics on overflow.
const maxTotalPower = 1 << 62

func (vs *ValidatorSet) validate() error {
	if len(vs.Validators) == 0 || vs.TotalPower == 0 {
		return errors.New("empty validator set")
	}
	if len(vs.Validators) > MaxValidators {
		return ufmt.Errorf("more than %d validators", MaxValidators)
	}
	seen := make(map[string]bool, len(vs.Validators))
	var total uint64
	for _, v := range vs.Validators {
		if len(v.PubKey) != pubKeySize || v.Power == 0 || string(v.Address) != string(addressOf(v.PubKey)) ||
			!isEdwardsPoint(v.PubKey) {
			return errors.New("invalid validator")
		}
		if seen[string(v.Address)] {
			return errors.New("duplicate validator")
		}
		seen[string(v.Address)] = true
		// Checked before adding, so the sum cannot wrap.
		if v.Power > maxTotalPower-total {
			return errors.New("total voting power overflows")
		}
		total += v.Power
	}
	if total != vs.TotalPower {
		return errors.New("validator set total power mismatch")
	}
	return nil
}

// Equal reports whether vs and o hold the same validators with the same
// powers, in any order: a certificate's signatures are matched by address,
// so the order does not change what a set certifies, and the registry's
// order can change without its members changing (a removal moves its last
// entry into the gap). Each validator of o is matched at most once, so
// equal lengths make the match exact.
func (vs *ValidatorSet) Equal(o *ValidatorSet) bool {
	if len(vs.Validators) != len(o.Validators) || vs.TotalPower != o.TotalPower {
		return false
	}
	powers := make(map[string]uint64, len(vs.Validators))
	for _, v := range vs.Validators {
		powers[string(v.PubKey)] = v.Power
	}
	for _, v := range o.Validators {
		p, ok := powers[string(v.PubKey)]
		if !ok || p != v.Power {
			return false
		}
		delete(powers, string(v.PubKey))
	}
	return true
}

func cloneBytes(b []byte) []byte {
	if b == nil {
		return nil
	}
	return append([]byte{}, b...)
}
