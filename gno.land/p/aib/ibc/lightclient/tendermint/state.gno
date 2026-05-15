package tendermint

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"strings"
	"time"

	"gno.land/p/aib/encoding/proto"
	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/ufmt/v0"
)

// ClientState from Tendermint tracks the current validator set, latest height,
// and a possible frozen height.
type ClientState struct {
	ChainID    string
	TrustLevel Fraction
	// duration of the period since the LatestTimestamp during which the
	// submitted headers are valid for upgrade
	TrustingPeriod time.Duration
	// duration of the staking unbonding period
	UnbondingPeriod time.Duration
	// defines how much new (untrusted) header's Time can drift into the future.
	MaxClockDrift time.Duration
	// Block height when the client was frozen due to a misbehaviour
	FrozenHeight types.Height
	// Latest height the client was updated to
	LatestHeight types.Height
	// Proof specifications used in verifying counterparty state
	ProofSpecs []*ics23.ProofSpec

	// Path at which next upgraded client will be committed.
	// Each element corresponds to the key for a single CommitmentProof in the
	// chained proof. NOTE: ClientState must stored under
	// `{upgradePath}/{upgradeHeight}/clientState` ConsensusState must be stored
	// under `{upgradepath}/{upgradeHeight}/consensusState` For SDK chains using
	// the default upgrade module, upgrade_path should be []string{"upgrade",
	// "upgradedIBCState"}`
	UpgradePath []string
}

func NewClientState(chainID string, trustLevel Fraction,
	trustingPeriod, ubdPeriod, maxClockDrift time.Duration,
	latestHeight types.Height, specs []*ics23.ProofSpec, upgradePath []string) *ClientState {
	return &ClientState{
		ChainID:         chainID,
		TrustLevel:      trustLevel,
		TrustingPeriod:  trustingPeriod,
		UnbondingPeriod: ubdPeriod,
		MaxClockDrift:   maxClockDrift,
		LatestHeight:    latestHeight,
		FrozenHeight:    types.ZeroHeight(),
		ProofSpecs:      specs,
		UpgradePath:     upgradePath,
	}
}

type Fraction struct {
	Numerator   uint64
	Denominator uint64
}

func NewFraction(numerator, denominator uint64) Fraction {
	return Fraction{
		Numerator:   numerator,
		Denominator: denominator,
	}
}

// DefaultTrustLevel is the tendermint light client default trust level
var DefaultTrustLevel = NewFraction(1, 3)

// ConsensusState defines the consensus state from Tendermint.
type ConsensusState struct {
	// timestamp that corresponds to the block height in which the ConsensusState
	// was stored.
	Timestamp time.Time
	// commitment root (i.e app hash)
	Root               MerkleRoot
	NextValidatorsHash []byte

	processedTime   time.Time
	processedHeight types.Height
}

func (cs ConsensusState) Equal(other ConsensusState) bool {
	return cs.Timestamp.Equal(other.Timestamp) &&
		bytes.Equal(cs.Root.Hash, other.Root.Hash) &&
		bytes.Equal(cs.NextValidatorsHash, other.NextValidatorsHash)
}

type MerkleRoot struct {
	Hash []byte
}

func NewMerkleRoot(hash []byte) MerkleRoot {
	return MerkleRoot{Hash: hash}
}

// Empty returns true if the root is empty
func (mr MerkleRoot) Empty() bool {
	return len(mr.Hash) == 0
}

const (
	// MaxChainIDLen is a maximum length of the chain ID.
	MaxChainIDLen = 50
	// SentinelRoot is used as a stand-in root value for the consensus state set at the upgrade height
	SentinelRoot = "sentinel_root"
	// ClientStateTypeURL is the proto Any type URL counterparties use when
	// storing the upgraded ClientState via cdc.MarshalInterface.
	ClientStateTypeURL = "/ibc.lightclients.tendermint.v1.ClientState"
	// ConsensusStateTypeURL is the proto Any type URL counterparties use
	// when storing the upgraded ConsensusState via cdc.MarshalInterface.
	ConsensusStateTypeURL = "/ibc.lightclients.tendermint.v1.ConsensusState"
)

// Implements lightclient.ClientState
func (ClientState) ClientType() string {
	return lightclient.Tendermint
}

// Implements lightclient.ClientState
func (cs ClientState) ValidateBasic() error {
	if strings.TrimSpace(cs.ChainID) == "" {
		return ufmt.Errorf("chainID cannot be empty string")
	}

	if len(cs.ChainID) > MaxChainIDLen {
		return ufmt.Errorf("chainID is too long; got: %d, max: %d", len(cs.ChainID), MaxChainIDLen)
	}

	if err := ValidateTrustLevel(cs.TrustLevel); err != nil {
		return err
	}
	if cs.TrustingPeriod <= 0 {
		return errors.New("trusting period must be greater than zero")
	}
	if cs.UnbondingPeriod <= 0 {
		return errors.New("unbonding period must be greater than zero")
	}
	if cs.MaxClockDrift <= 0 {
		return errors.New("max clock drift must be greater than zero")
	}

	// the latest height revision number must match the chain id revision number
	if cs.LatestHeight.RevisionNumber != types.ParseChainID(cs.ChainID) {
		return ufmt.Errorf("latest height revision number must match chain id revision number (%d != %d)", cs.LatestHeight.RevisionNumber, types.ParseChainID(cs.ChainID))
	}
	if cs.LatestHeight.RevisionHeight == 0 {
		return ufmt.Errorf("tendermint client's latest height revision height cannot be zero")
	}
	if cs.TrustingPeriod >= cs.UnbondingPeriod {
		return ufmt.Errorf("trusting period (%s) should be < unbonding period (%s)", cs.TrustingPeriod, cs.UnbondingPeriod)
	}

	if cs.ProofSpecs == nil {
		return ufmt.Errorf("proof specs cannot be nil for tm client")
	}
	for i, spec := range cs.ProofSpecs {
		if spec == nil {
			return ufmt.Errorf("proof spec cannot be nil at index: %d", i)
		}
	}
	// UpgradePath may be empty, but if it isn't, each key must be non-empty
	for i, k := range cs.UpgradePath {
		if strings.TrimSpace(k) == "" {
			return ufmt.Errorf("key in upgrade path at index %d cannot be empty", i)
		}
	}

	return nil
}

// ValidateTrustLevel checks that trustLevel is within the allowed range [1/3,
// 1]. If not, it returns an error. 1/3 is the minimum amount of trust needed
// which does not break the security model.
func ValidateTrustLevel(lvl Fraction) error {
	if lvl.Numerator*3 < lvl.Denominator || // < 1/3
		lvl.Numerator > lvl.Denominator || // > 1
		lvl.Denominator == 0 {
		return ufmt.Errorf("trustLevel must be within [1/3, 1], given %v", lvl)
	}
	return nil
}

// Implements lightclient.ConsensusState
func (ConsensusState) ClientType() string {
	return lightclient.Tendermint
}

// Implements lightclient.ConsensusState
func (cs ConsensusState) ValidateBasic() error {
	if cs.Root.Empty() {
		return errors.New("root cannot be empty")
	}
	if err := validateHash(cs.NextValidatorsHash); err != nil {
		return ufmt.Errorf("next validators hash is invalid: %v", err)
	}
	if cs.Timestamp.Unix() <= 0 {
		return errors.New("timestamp must be a positive Unix time")
	}
	return nil
}

// validateHash returns an error if the hash is not empty, but its
// size != tmhash.Size.
func validateHash(h []byte) error {
	if len(h) > 0 && len(h) != sha256.Size {
		return ufmt.Errorf("expected size to be %d bytes, got %d bytes",
			sha256.Size,
			len(h),
		)
	}
	return nil
}

func (cs ClientState) ProtoMarshal() (bz []byte) {
	if cs.ChainID != "" {
		bz = proto.AppendLengthDelimited(bz, 1, []byte(cs.ChainID))
	}
	// Fields 2..7 are marked `(gogoproto.nullable) = false` in ibc-go's
	// .proto, so they're emitted even when zero (as length-0 messages).
	bz = proto.AppendAlwaysLengthDelimited(bz, 2, cs.TrustLevel.ProtoMarshal())
	bz = proto.AppendAlwaysLengthDelimited(bz, 3, proto.DurationMarshal(cs.TrustingPeriod))
	bz = proto.AppendAlwaysLengthDelimited(bz, 4, proto.DurationMarshal(cs.UnbondingPeriod))
	bz = proto.AppendAlwaysLengthDelimited(bz, 5, proto.DurationMarshal(cs.MaxClockDrift))
	bz = proto.AppendAlwaysLengthDelimited(bz, 6, cs.FrozenHeight.ProtoMarshal())
	bz = proto.AppendAlwaysLengthDelimited(bz, 7, cs.LatestHeight.ProtoMarshal())
	for _, spec := range cs.ProofSpecs {
		bz = proto.AppendLengthDelimited(bz, 8, spec.ProtoMarshal())
	}
	for _, path := range cs.UpgradePath {
		bz = proto.AppendLengthDelimited(bz, 9, []byte(path))
	}
	return
}

// ZeroCustomFields returns a copy of the ClientState with all
// client-customizable fields zeroed. Only the chain-specified fields
// (ChainID, UnbondingPeriod, LatestHeight, ProofSpecs, UpgradePath) are
// preserved. The counterparty chain commits to this zeroed form when
// scheduling an upgrade, so verification on the upgrade proof must be
// performed against the same shape.
func (cs ClientState) ZeroCustomFields() ClientState {
	return ClientState{
		ChainID:         cs.ChainID,
		UnbondingPeriod: cs.UnbondingPeriod,
		LatestHeight:    cs.LatestHeight,
		ProofSpecs:      cs.ProofSpecs,
		UpgradePath:     cs.UpgradePath,
	}
}

func (f Fraction) ProtoMarshal() (bz []byte) {
	bz = proto.AppendVarint(bz, 1, f.Numerator)
	bz = proto.AppendVarint(bz, 2, f.Denominator)
	return
}

func (cs ConsensusState) ProtoMarshal() (bz []byte) {
	// Timestamp and Root are `(gogoproto.nullable) = false` in ibc-go;
	// always-emit semantics. NextValidatorsHash is plain bytes — proto3
	// default applies (omitted when empty).
	bz = proto.AppendAlwaysLengthDelimited(bz, 1, proto.TimeMarshal(cs.Timestamp))
	bz = proto.AppendAlwaysLengthDelimited(bz, 2, cs.Root.ProtoMarshal())
	bz = proto.AppendLengthDelimited(bz, 3, cs.NextValidatorsHash)
	return
}

func (mr MerkleRoot) ProtoMarshal() (bz []byte) {
	bz = proto.AppendLengthDelimited(bz, 1, mr.Hash)
	return
}
