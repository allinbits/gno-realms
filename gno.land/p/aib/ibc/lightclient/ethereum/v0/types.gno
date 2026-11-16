package ethereum

import (
	"bytes"
	"errors"

	"gno.land/p/nt/ufmt/v0"
)

// ClientType is the IBC client type of this light client; client IDs are
// ethereum-<n>.
const ClientType = "ethereum"

// Generalized indices of the light-client proofs. Electra's hold through
// Fulu; Gloas (EIP-7688, EIP-7732) moved them. See the light-client sync
// protocols of both forks.
const (
	finalizedRootGindexElectra     = 169
	nextSyncCommitteeGindexElectra = 87
	executionPayloadGindex         = 25

	finalizedRootGindexGloas      = 735
	nextSyncCommitteeGindexGloas  = 2946
	executionBlockHashGindexGloas = 2856

	// executionBlockHashGindexDeneb is the payload's block_hash in a Deneb
	// to Fulu body: the gindex of an Electra or Fulu header converted to
	// Gloas' hash form.
	executionBlockHashGindexDeneb = 812
)

// FarFutureEpoch marks a fork that is not scheduled.
const FarFutureEpoch = ^uint64(0)

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
	// GenesisSlot duplicates ClientState.GenesisSlot, which the client
	// computes with; ValidateBasic requires the two equal. It is kept for
	// parity with eureka's fork parameters and the wire formats that carry it.
	GenesisSlot uint64
	Altair      Fork
	Bellatrix   Fork
	Capella     Fork
	Deneb       Fork
	Electra     Fork
	Fulu        Fork
	// Gloas is the ePBS fork. Set its epoch to FarFutureEpoch while it is
	// not scheduled.
	Gloas Fork
}

// validate checks that the forks are scheduled in order, that every scheduled
// fork has a version, and that Electra, the first supported fork, is scheduled.
// A fork left as a zero Fork{} would otherwise be active from genesis: the
// version check catches it where ordering cannot, when every earlier fork is at
// epoch 0. Every real fork version from Altair on is non-zero; only mainnet's
// genesis version is 0x00000000, so GenesisForkVersion is not checked.
func (p ForkParameters) validate() error {
	prev := uint64(0)
	for i, f := range p.forks() {
		if f.Epoch < prev {
			return ufmt.Errorf("%s fork epoch %d precedes the previous fork's %d", forkNames[i], f.Epoch, prev)
		}
		if f.Epoch != FarFutureEpoch && f.Version == ([4]byte{}) {
			return ufmt.Errorf("%s fork is scheduled at epoch %d without a version", forkNames[i], f.Epoch)
		}
		prev = f.Epoch
	}
	if p.Electra.Epoch == FarFutureEpoch {
		return errors.New("electra fork must be scheduled")
	}
	return nil
}

var forkNames = []string{"altair", "bellatrix", "capella", "deneb", "electra", "fulu", "gloas"}

// forks lists the forks in activation order.
func (p ForkParameters) forks() []Fork {
	return []Fork{p.Altair, p.Bellatrix, p.Capella, p.Deneb, p.Electra, p.Fulu, p.Gloas}
}

// forkVersion implements compute_fork_version.
func (p ForkParameters) forkVersion(epoch uint64) [4]byte {
	switch {
	case epoch >= p.Gloas.Epoch:
		return p.Gloas.Version
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
	case cs.SyncCommitteeSize < 8 || cs.SyncCommitteeSize&(cs.SyncCommitteeSize-1) != 0 || cs.SyncCommitteeSize > 1<<maxZeroHashDepth:
		return ufmt.Errorf("invalid sync committee size %d", cs.SyncCommitteeSize)
	case cs.MinSyncCommitteeParticipants == 0 || cs.MinSyncCommitteeParticipants > cs.SyncCommitteeSize:
		return ufmt.Errorf("invalid min sync committee participants %d", cs.MinSyncCommitteeParticipants)
	case cs.SecondsPerSlot == 0 || cs.SlotsPerEpoch == 0 || cs.EpochsPerSyncCommitteePeriod == 0:
		return errors.New("seconds per slot, slots per epoch and epochs per period must be positive")
	case cs.EpochsPerSyncCommitteePeriod > maxUint64/cs.SlotsPerEpoch/TrustingPeriods:
		// The trusting window, TrustingPeriods periods in slots, must not wrap.
		return errors.New("slots per epoch and epochs per period overflow the trusting window")
	case cs.LatestSlot < cs.GenesisSlot:
		return errors.New("latest slot precedes genesis slot")
	case cs.IsFrozen:
		return errors.New("cannot create a frozen client")
	case len(cs.IBCContractAddress) != addressSize:
		return errors.New("ibc contract address must be 20 bytes")
	case len(cs.IBCCommitmentSlot) != hashSize:
		return errors.New("ibc commitment slot must be 32 bytes")
	}
	// The forks pick the signing domain (forkVersion), the Merkle layout
	// (isGloas) and the supported range (verifySupportedFork): a client
	// created with a wrong schedule would accept no update.
	if cs.ForkParameters.GenesisSlot != cs.GenesisSlot {
		return ufmt.Errorf("fork parameters genesis slot %d differs from genesis slot %d", cs.ForkParameters.GenesisSlot, cs.GenesisSlot)
	}
	if err := cs.ForkParameters.validate(); err != nil {
		return err
	}
	return cs.verifySupportedFork(cs.LatestSlot)
}

func (cs ClientState) epochAtSlot(slot uint64) uint64 { return slot / cs.SlotsPerEpoch }

func (cs ClientState) periodAtSlot(slot uint64) uint64 {
	return cs.epochAtSlot(slot) / cs.EpochsPerSyncCommitteePeriod
}

// slotAtTimestamp returns the slot at unix time t, and false before genesis
// or when the slot does not fit in a uint64.
func (cs ClientState) slotAtTimestamp(t uint64) (uint64, bool) {
	elapsed, ok := cs.elapsedSlots(t)
	if !ok || elapsed > maxUint64-cs.GenesisSlot {
		return 0, false
	}
	return elapsed + cs.GenesisSlot, true
}

// elapsedSlots is how many slots have passed since genesis at unix time t,
// and false before genesis. Unlike the slot itself it cannot wrap.
func (cs ClientState) elapsedSlots(t uint64) (uint64, bool) {
	if t < cs.GenesisTime {
		return 0, false
	}
	return (t - cs.GenesisTime) / cs.SecondsPerSlot, true
}

// trustWindow is how many slots past its latest trusted slot the client
// stays usable: TrustingPeriods sync committee periods. ValidateBasic bounds
// the parameters so that it does not wrap.
func (cs ClientState) trustWindow() uint64 {
	return TrustingPeriods * cs.EpochsPerSyncCommitteePeriod * cs.SlotsPerEpoch
}

const maxUint64 = ^uint64(0)

func (cs ClientState) isGloas(slot uint64) bool {
	return cs.epochAtSlot(slot) >= cs.ForkParameters.Gloas.Epoch
}

func (cs ClientState) finalizedRootGindex(slot uint64) uint64 {
	if cs.isGloas(slot) {
		return finalizedRootGindexGloas
	}
	return finalizedRootGindexElectra
}

func (cs ClientState) nextSyncCommitteeGindex(slot uint64) uint64 {
	if cs.isGloas(slot) {
		return nextSyncCommitteeGindexGloas
	}
	return nextSyncCommitteeGindexElectra
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
	return bytes.Equal(s.PubkeysHash, o.PubkeysHash) && bytes.Equal(s.AggregatePubkey, o.AggregatePubkey)
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

// validateBranch requires every node of a Merkle branch to be one 32-byte
// chunk: a longer or shorter node would change where its bytes fall in the
// parent hash.
func validateBranch(branch [][]byte) error {
	for i, node := range branch {
		if len(node) != hashSize {
			return ufmt.Errorf("node %d is %d bytes, not 32", i, len(node))
		}
	}
	return nil
}

// validateSizes checks the fixed-size fields SSZ hashes as whole chunks.
func (h BeaconBlockHeader) validateSizes() error {
	if len(h.ParentRoot) != hashSize || len(h.StateRoot) != hashSize || len(h.BodyRoot) != hashSize {
		return errors.New("beacon header roots must be 32 bytes")
	}
	return nil
}

// validateSizes checks every field of the execution payload header against its
// SSZ size: fixed-size fields exactly, bounded ones within their bound.
func (h ExecutionPayloadHeader) validateSizes() error {
	for _, f := range []struct {
		name string
		b    []byte
		size int
	}{
		{"parent hash", h.ParentHash, hashSize},
		{"fee recipient", h.FeeRecipient, 20},
		{"state root", h.StateRoot, hashSize},
		{"receipts root", h.ReceiptsRoot, hashSize},
		{"logs bloom", h.LogsBloom, logsBloomSize},
		{"prev randao", h.PrevRandao, hashSize},
		{"block hash", h.BlockHash, hashSize},
		{"transactions root", h.TransactionsRoot, hashSize},
		{"withdrawals root", h.WithdrawalsRoot, hashSize},
	} {
		if len(f.b) != f.size {
			return ufmt.Errorf("execution header %s must be %d bytes, got %d", f.name, f.size, len(f.b))
		}
	}
	if len(h.ExtraData) > maxExtraDataLen {
		return ufmt.Errorf("execution header extra data exceeds %d bytes", maxExtraDataLen)
	}
	if len(h.BaseFeePerGas) > chunkSize {
		return errors.New("execution header base fee exceeds 32 bytes")
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

// LightClientHeader is a beacon header with the execution data it commits to
// and the branch proving it in the beacon block body. Before Gloas that is
// the execution payload header (Execution) or, in Gloas' converted form, only
// its block hash (ExecutionBlockHash); from Gloas on, it is only the hash of
// the latest execution block (ExecutionBlockHash).
type LightClientHeader struct {
	Beacon             BeaconBlockHeader
	Execution          ExecutionPayloadHeader
	ExecutionBlockHash []byte
	ExecutionBranch    [][]byte
}

// hashForm reports whether h carries its execution as a block hash, the form
// of every Gloas header and of an earlier one converted to Gloas.
func (h LightClientHeader) hashForm() bool { return len(h.ExecutionBlockHash) > 0 }

// isEmpty reports whether no field of h is set: a header in the hash form
// carries no payload header.
func (h ExecutionPayloadHeader) isEmpty() bool {
	for _, b := range [][]byte{h.ParentHash, h.FeeRecipient, h.StateRoot, h.ReceiptsRoot, h.LogsBloom,
		h.PrevRandao, h.ExtraData, h.BaseFeePerGas, h.BlockHash, h.TransactionsRoot, h.WithdrawalsRoot} {
		if len(b) != 0 {
			return false
		}
	}
	return h.BlockNumber == 0 && h.GasLimit == 0 && h.GasUsed == 0 && h.Timestamp == 0 &&
		h.BlobGasUsed == 0 && h.ExcessBlobGas == 0
}

// committeeRoot is the hash_tree_root of the SyncCommittee container the
// summary commits to.
func (s SummarizedSyncCommittee) committeeRoot() []byte {
	agg := hash2(s.AggregatePubkey[:chunkSize], padChunk(s.AggregatePubkey[chunkSize:]))
	return hash2(s.PubkeysHash, agg)
}

// NonSigner is a sync committee member whose participation bit is unset: its
// public key and the branch proving it at its index in the committee's
// pubkeys vector.
type NonSigner struct {
	Pubkey []byte
	Branch [][]byte
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

// LightClientUpdate is a light-client update as served by the beacon API,
// with the sync committees reduced to what the client verifies: the next
// committee as its summary (its pubkeys root and aggregate key, which is all
// its branch commits to), and of the signing committee only the members that
// did not sign. NextSyncCommittee and NextSyncCommitteeBranch are both set or
// both unset.
type LightClientUpdate struct {
	AttestedHeader          LightClientHeader
	NextSyncCommittee       *SummarizedSyncCommittee
	NextSyncCommitteeBranch [][]byte
	FinalizedHeader         LightClientHeader
	FinalityBranch          [][]byte
	SyncAggregate           SyncAggregate
	SignatureSlot           uint64
	// FinalizedExecutionHeader is the RLP-encoded execution block header
	// whose hash is FinalizedHeader.ExecutionBlockHash, from which an update
	// whose finalized header is in the hash form takes the execution state
	// root. Unused when that header carries its payload header.
	FinalizedExecutionHeader []byte
	// NonSigners are the members of the signing committee whose bit in
	// SyncAggregate is unset, in committee order.
	NonSigners []NonSigner
}

func (u LightClientUpdate) validateBasic() error {
	if (u.NextSyncCommittee == nil) != (len(u.NextSyncCommitteeBranch) == 0) {
		return errors.New("next sync committee and its branch must be set together")
	}
	if u.NextSyncCommittee != nil {
		if err := validateSummary(*u.NextSyncCommittee); err != nil {
			return ufmt.Errorf("next sync committee: %v", err)
		}
	}
	if err := validateBranch(u.NextSyncCommitteeBranch); err != nil {
		return ufmt.Errorf("next sync committee branch: %v", err)
	}
	if err := validateBranch(u.FinalityBranch); err != nil {
		return ufmt.Errorf("finality branch: %v", err)
	}
	for i, ns := range u.NonSigners {
		if len(ns.Pubkey) != blsPubKeySize {
			return ufmt.Errorf("non-signer %d: pubkey is not 48 bytes", i)
		}
		if err := validateBranch(ns.Branch); err != nil {
			return ufmt.Errorf("non-signer %d branch: %v", i, err)
		}
	}
	if len(u.SyncAggregate.SyncCommitteeSignature) != blsSignatureSize {
		return errors.New("sync committee signature must be 96 bytes")
	}
	return nil
}

// Header is the client message that updates the client from the trusted
// consensus state at TrustedSlot. The update is signed by that state's
// current sync committee, or by its next one when signed in the period after
// it, as the signature slot says.
//
// ActiveIsNext is ignored: the client derives the signing committee from the
// signature period, as the sync protocol does. It is kept only because the
// wire format is positional and the relayers send it; it goes when they stop.
type Header struct {
	ActiveIsNext    bool
	ConsensusUpdate LightClientUpdate
	TrustedSlot     uint64
}

func (*Header) ClientType() string { return ClientType }

func (h *Header) ValidateBasic() error {
	return h.ConsensusUpdate.validateBasic()
}

// Misbehaviour is two valid updates finalizing different beacon headers at
// the same slot. ActiveIsNext is ignored, as in Header.
type Misbehaviour struct {
	ActiveIsNext bool
	Update1      LightClientUpdate
	Update2      LightClientUpdate
	TrustedSlot  uint64
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
