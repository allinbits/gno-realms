package ethereum

import (
	"errors"

	"gno.land/p/nt/ufmt/v0"
)

// ClientType is the IBC client type of this light client; client IDs are
// ethereum-<n>.
const ClientType = "ethereum"

// Generalized indices of the light-client proofs, from Electra on (Fulu did
// not change them). See the Electra light-client sync protocol.
const (
	finalizedRootGindex        = 169
	currentSyncCommitteeGindex = 86
	nextSyncCommitteeGindex    = 87
	executionPayloadGindex     = 25
)

var domainSyncCommittee = [4]byte{0x07, 0x00, 0x00, 0x00}

const (
	blsPubKeySize    = 48
	blsSignatureSize = 96
	hashSize         = 32
	addressSize      = 20
)

// Fork is a consensus fork version and its activation epoch.
type Fork struct {
	Version [4]byte
	Epoch   uint64
}

// ForkParameters are the forks of the tracked chain.
type ForkParameters struct {
	GenesisForkVersion [4]byte
	GenesisSlot        uint64
	Altair             Fork
	Bellatrix          Fork
	Capella            Fork
	Deneb              Fork
	Electra            Fork
	Fulu               Fork
}

// forkVersion implements compute_fork_version.
func (p ForkParameters) forkVersion(epoch uint64) [4]byte {
	switch {
	case epoch >= p.Fulu.Epoch:
		return p.Fulu.Version
	case epoch >= p.Electra.Epoch:
		return p.Electra.Version
	case epoch >= p.Deneb.Epoch:
		return p.Deneb.Version
	case epoch >= p.Capella.Epoch:
		return p.Capella.Version
	case epoch >= p.Bellatrix.Epoch:
		return p.Bellatrix.Version
	case epoch >= p.Altair.Epoch:
		return p.Altair.Version
	}
	return p.GenesisForkVersion
}

// ClientState is the state of an Ethereum light client. It mirrors the
// client state of the Ethereum light client in cosmos/solidity-ibc-eureka.
type ClientState struct {
	ChainID                      uint64
	GenesisValidatorsRoot        []byte
	MinSyncCommitteeParticipants uint64
	SyncCommitteeSize            uint64
	GenesisTime                  uint64
	GenesisSlot                  uint64
	ForkParameters               ForkParameters
	SecondsPerSlot               uint64
	SlotsPerEpoch                uint64
	EpochsPerSyncCommitteePeriod uint64
	LatestSlot                   uint64
	LatestExecutionBlockNumber   uint64
	IsFrozen                     bool
	// IBCContractAddress is the ICS26 router whose storage holds the
	// commitments, and IBCCommitmentSlot the storage slot of its commitments
	// mapping.
	IBCContractAddress []byte
	IBCCommitmentSlot  []byte
}

func (ClientState) ClientType() string { return ClientType }

func (cs ClientState) ValidateBasic() error {
	switch {
	case len(cs.GenesisValidatorsRoot) != hashSize:
		return errors.New("genesis validators root must be 32 bytes")
	case cs.SyncCommitteeSize == 0 || cs.SyncCommitteeSize%8 != 0 || cs.SyncCommitteeSize > 1<<maxZeroHashDepth:
		return ufmt.Errorf("invalid sync committee size %d", cs.SyncCommitteeSize)
	case cs.MinSyncCommitteeParticipants == 0 || cs.MinSyncCommitteeParticipants > cs.SyncCommitteeSize:
		return ufmt.Errorf("invalid min sync committee participants %d", cs.MinSyncCommitteeParticipants)
	case cs.SecondsPerSlot == 0 || cs.SlotsPerEpoch == 0 || cs.EpochsPerSyncCommitteePeriod == 0:
		return errors.New("seconds per slot, slots per epoch and epochs per period must be positive")
	case cs.LatestSlot < cs.GenesisSlot:
		return errors.New("latest slot precedes genesis slot")
	case cs.IsFrozen:
		return errors.New("cannot create a frozen client")
	case len(cs.IBCContractAddress) != addressSize:
		return errors.New("ibc contract address must be 20 bytes")
	case len(cs.IBCCommitmentSlot) != hashSize:
		return errors.New("ibc commitment slot must be 32 bytes")
	}
	return nil
}

func (cs ClientState) epochAtSlot(slot uint64) uint64 { return slot / cs.SlotsPerEpoch }

func (cs ClientState) periodAtSlot(slot uint64) uint64 {
	return cs.epochAtSlot(slot) / cs.EpochsPerSyncCommitteePeriod
}

// slotAtTimestamp returns the slot at unix time t, and false before genesis.
func (cs ClientState) slotAtTimestamp(t uint64) (uint64, bool) {
	if t < cs.GenesisTime {
		return 0, false
	}
	return (t-cs.GenesisTime)/cs.SecondsPerSlot + cs.GenesisSlot, true
}

// verifySupportedFork rejects slots before Electra, whose generalized
// indices differ from the ones this client uses.
func (cs ClientState) verifySupportedFork(slot uint64) error {
	if cs.epochAtSlot(slot) < cs.ForkParameters.Electra.Epoch {
		return ufmt.Errorf("slot %d is before Electra, which is not supported", slot)
	}
	return nil
}

// SummarizedSyncCommittee commits to a sync committee: PubkeysHash is the
// hash_tree_root of its pubkeys vector.
type SummarizedSyncCommittee struct {
	PubkeysHash     []byte
	AggregatePubkey []byte
}

func (s SummarizedSyncCommittee) equal(o SummarizedSyncCommittee) bool {
	return bytesEqual(s.PubkeysHash, o.PubkeysHash) && bytesEqual(s.AggregatePubkey, o.AggregatePubkey)
}

// ConsensusState is the state trusted at a finalized beacon slot. StateRoot is
// the execution state root, against which storage proofs are verified, and
// Timestamp the execution block time in seconds.
type ConsensusState struct {
	Slot                 uint64
	StateRoot            []byte
	Timestamp            uint64
	CurrentSyncCommittee SummarizedSyncCommittee
	NextSyncCommittee    *SummarizedSyncCommittee
}

func (ConsensusState) ClientType() string { return ClientType }

func (cs ConsensusState) ValidateBasic() error {
	if len(cs.StateRoot) != hashSize {
		return errors.New("state root must be 32 bytes")
	}
	if err := validateSummary(cs.CurrentSyncCommittee); err != nil {
		return ufmt.Errorf("current sync committee: %v", err)
	}
	if cs.NextSyncCommittee != nil {
		if err := validateSummary(*cs.NextSyncCommittee); err != nil {
			return ufmt.Errorf("next sync committee: %v", err)
		}
	}
	return nil
}

func validateSummary(s SummarizedSyncCommittee) error {
	if len(s.PubkeysHash) != hashSize {
		return errors.New("pubkeys hash must be 32 bytes")
	}
	if len(s.AggregatePubkey) != blsPubKeySize {
		return errors.New("aggregate pubkey must be 48 bytes")
	}
	return nil
}

// BeaconBlockHeader is the consensus-layer block header.
type BeaconBlockHeader struct {
	Slot          uint64
	ProposerIndex uint64
	ParentRoot    []byte
	StateRoot     []byte
	BodyRoot      []byte
}

// ExecutionPayloadHeader is the Deneb-and-later execution payload header.
// BaseFeePerGas is a big-endian uint256 of at most 32 bytes.
type ExecutionPayloadHeader struct {
	ParentHash       []byte
	FeeRecipient     []byte
	StateRoot        []byte
	ReceiptsRoot     []byte
	LogsBloom        []byte
	PrevRandao       []byte
	BlockNumber      uint64
	GasLimit         uint64
	GasUsed          uint64
	Timestamp        uint64
	ExtraData        []byte
	BaseFeePerGas    []byte
	BlockHash        []byte
	TransactionsRoot []byte
	WithdrawalsRoot  []byte
	BlobGasUsed      uint64
	ExcessBlobGas    uint64
}

// LightClientHeader is a beacon header with its execution payload header and
// the branch proving the latter in the beacon block body.
type LightClientHeader struct {
	Beacon          BeaconBlockHeader
	Execution       ExecutionPayloadHeader
	ExecutionBranch [][]byte
}

// SyncCommittee is a full sync committee.
type SyncCommittee struct {
	Pubkeys         [][]byte
	AggregatePubkey []byte
}

func (c SyncCommittee) summarize() SummarizedSyncCommittee {
	return SummarizedSyncCommittee{
		PubkeysHash:     pubkeysRoot(c.Pubkeys),
		AggregatePubkey: c.AggregatePubkey,
	}
}

// hashTreeRoot of the SyncCommittee container.
func (c SyncCommittee) hashTreeRoot() []byte {
	agg := hash2(c.AggregatePubkey[:chunkSize], padChunk(c.AggregatePubkey[chunkSize:]))
	return hash2(pubkeysRoot(c.Pubkeys), agg)
}

func (c SyncCommittee) validate(size uint64) error {
	if uint64(len(c.Pubkeys)) != size {
		return ufmt.Errorf("sync committee has %d pubkeys, want %d", len(c.Pubkeys), size)
	}
	for i, pk := range c.Pubkeys {
		if len(pk) != blsPubKeySize {
			return ufmt.Errorf("sync committee pubkey %d is not 48 bytes", i)
		}
	}
	if len(c.AggregatePubkey) != blsPubKeySize {
		return errors.New("sync committee aggregate pubkey is not 48 bytes")
	}
	return nil
}

// SyncAggregate is the sync committee's signature over an attested header.
type SyncAggregate struct {
	SyncCommitteeBits      []byte
	SyncCommitteeSignature []byte
}

func (a SyncAggregate) participants() uint64 {
	var n uint64
	for _, b := range a.SyncCommitteeBits {
		for ; b != 0; b &= b - 1 {
			n++
		}
	}
	return n
}

func (a SyncAggregate) size() uint64 { return uint64(len(a.SyncCommitteeBits)) * 8 }

// LightClientUpdate is a light-client update as served by the beacon API.
// NextSyncCommittee and NextSyncCommitteeBranch are both set or both unset.
type LightClientUpdate struct {
	AttestedHeader          LightClientHeader
	NextSyncCommittee       *SyncCommittee
	NextSyncCommitteeBranch [][]byte
	FinalizedHeader         LightClientHeader
	FinalityBranch          [][]byte
	SyncAggregate           SyncAggregate
	SignatureSlot           uint64
}

func (u LightClientUpdate) validateBasic() error {
	if (u.NextSyncCommittee == nil) != (len(u.NextSyncCommitteeBranch) == 0) {
		return errors.New("next sync committee and its branch must be set together")
	}
	if len(u.SyncAggregate.SyncCommitteeSignature) != blsSignatureSize {
		return errors.New("sync committee signature must be 96 bytes")
	}
	return nil
}

// Header is the client message that updates the client. ActiveSyncCommittee
// is the full committee whose summary the trusted consensus state at
// TrustedSlot holds: the current one, or the next one if ActiveIsNext.
type Header struct {
	ActiveSyncCommittee SyncCommittee
	ActiveIsNext        bool
	ConsensusUpdate     LightClientUpdate
	TrustedSlot         uint64
}

func (*Header) ClientType() string { return ClientType }

func (h *Header) ValidateBasic() error {
	return h.ConsensusUpdate.validateBasic()
}

// Misbehaviour is two valid updates attesting different execution state
// roots at the same slot.
type Misbehaviour struct {
	ActiveSyncCommittee SyncCommittee
	ActiveIsNext        bool
	Update1             LightClientUpdate
	Update2             LightClientUpdate
	TrustedSlot         uint64
}

func (*Misbehaviour) ClientType() string { return ClientType }

func (m *Misbehaviour) ValidateBasic() error {
	if err := m.Update1.validateBasic(); err != nil {
		return err
	}
	return m.Update2.validateBasic()
}

// MembershipProof proves a storage slot of the ICS26 router: AccountProof is
// eth_getProof's accountProof for the router and StorageProof the proof of
// the slot in its storage trie.
type MembershipProof struct {
	AccountProof [][]byte
	StorageProof [][]byte
}
