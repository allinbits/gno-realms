package tendermint

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"time"

	"gno.land/p/aib/encoding/proto"
	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt"
)

// MsgHeader defines the Tendermint client consensus Header.
// It encapsulates all the information necessary to update from a trusted
// Tendermint ConsensusState. The inclusion of TrustedHeight and
// TrustedValidators allows this update to process correctly, so long as the
// ConsensusState for the TrustedHeight exists, this removes race conditions
// among relayers The SignedHeader and ValidatorSet are the new untrusted update
// fields for the client. The TrustedHeight is the height of a stored
// ConsensusState on the client that will be used to verify the new untrusted
// header. The Trusted ConsensusState must be within the unbonding period of
// current time in order to correctly verify, and the TrustedValidators must
// hash to TrustedConsensusState.NextValidatorsHash since that is the last
// trusted validator set at the TrustedHeight.
type MsgHeader struct {
	Header            *Header
	Commit            *Commit
	ValidatorSet      *ValidatorSet
	TrustedHeight     types.Height
	TrustedValidators *ValidatorSet
}

func NewMsgHeader(chainID string, timestamp time.Time,
	apphash, blockhash, parsethash, consensushash []byte,
	height uint64, trustedHeight types.Height,
	valset, trustedValset *ValidatorSet,
	signatures []CommitSig) *MsgHeader {
	return &MsgHeader{
		Header: &Header{
			Version: Consensus{
				Block: BlockProtocol,
				App:   0,
			},
			ChainID: chainID,
			Height:  height,
			Time:    timestamp,
			LastBlockID: BlockID{
				Hash: blockhash,
				PartSetHeader: PartSetHeader{
					Total: 1,
					Hash:  parsethash,
				},
			},
			LastCommitHash:     apphash, //FIXME
			DataHash:           apphash, //FIXME
			ValidatorsHash:     valset.Hash(),
			NextValidatorsHash: trustedValset.Hash(),
			ConsensusHash:      consensushash,
			AppHash:            apphash,
			LastResultsHash:    nil, //FIXME?
			EvidenceHash:       nil, //FIXME?
			ProposerAddress:    valset.Proposer.Address,
		},
		Commit: &Commit{
			Height: height,
			Round:  0,
			BlockID: BlockID{
				Hash: blockhash,
				PartSetHeader: PartSetHeader{
					Total: 1,
					Hash:  parsethash,
				},
			},
			Signatures: signatures,
		},
		ValidatorSet:      valset,
		TrustedHeight:     trustedHeight,
		TrustedValidators: trustedValset,
	}
}

// Implements lightclient.ClientMessage
func (*MsgHeader) ClientType() string {
	return lightclient.Tendermint
}

// Implements lightclient.ClientMessage
// NOTE: TrustedHeight and TrustedValidators may be empty when creating client
// with MsgCreateClient
func (h *MsgHeader) ValidateBasic() error {
	if h.Header == nil {
		return errors.New("missing header")
	}
	if h.Commit == nil {
		return errors.New("missing commit")
	}
	if err := h.Header.ValidateBasic(); err != nil {
		return ufmt.Errorf("invalid header: %v", err)
	}
	if err := h.Commit.ValidateBasic(); err != nil {
		return ufmt.Errorf("invalid commit: %v", err)
	}
	// Make sure the header is consistent with the commit.
	if h.Header.Height != h.Commit.Height {
		return ufmt.Errorf("header and commit height mismatch: %d vs %d", h.Header.Height, h.Commit.Height)
	}
	if hhash, chash := h.Header.Hash(), h.Commit.BlockID.Hash; !bytes.Equal(hhash, chash) {
		cs, hs := hex.EncodeToString(chash), hex.EncodeToString(hhash)
		return ufmt.Errorf("expected BlockID#Hash and Header#Hash to be the same, got %q != %q", cs, hs)
	}

	// TrustedHeight is less than Header for updates and misbehaviour
	if h.TrustedHeight.GTE(h.GetHeight()) {
		return ufmt.Errorf("trustedHeight %s must be less than header height %s",
			h.TrustedHeight, h.GetHeight())
	}

	if h.ValidatorSet == nil {
		return ufmt.Errorf("validator set is nil")
	}
	if h.TrustedValidators == nil {
		return ufmt.Errorf("trusted validator set is nil")
	}
	if !bytes.Equal(h.Header.ValidatorsHash, h.ValidatorSet.Hash()) {
		return ufmt.Errorf("validator set does not match hash")
	}
	if !bytes.Equal(h.Header.NextValidatorsHash, h.TrustedValidators.Hash()) {
		return ufmt.Errorf("trusted validator set does not match hash")
	}
	if len(h.ValidatorSet.Validators) != len(h.Commit.Signatures) {
		return ufmt.Errorf("Invalid commit -- wrong set size: %v vs %v",
			len(h.ValidatorSet.Validators), len(h.Commit.Signatures))
	}
	return nil
}

// ConsensusState returns the updated consensus state associated with the
// header
func (h MsgHeader) ConsensusState() ConsensusState {
	return ConsensusState{
		Timestamp:          h.Header.Time,
		Root:               NewMerkleRoot(h.Header.AppHash),
		NextValidatorsHash: h.Header.NextValidatorsHash,
	}
}

// GetHeight returns the current height. It returns 0 if the tendermint
// header is nil.
// NOTE: the header.Header is checked to be non nil in ValidateBasic.
func (h MsgHeader) GetHeight() types.Height {
	revision := types.ParseChainID(h.Header.ChainID)
	return types.NewHeight(revision, h.Header.Height)
}

// Misbehaviour is a wrapper over two conflicting Headers
// that implements Misbehaviour interface expected by ICS-02
type Misbehaviour struct {
	Header1 *MsgHeader
	Header2 *MsgHeader
}

// Implements lightclient.ClientMessage
func (Misbehaviour) ClientType() string {
	return lightclient.Tendermint
}

// Implements lightclient.ClientMessage
func (m Misbehaviour) ValidateBasic() error {
	// TODO
	return nil
}

// Header defines the structure of a block header.
type Header struct {
	// basic block info
	Version Consensus
	ChainID string
	Height  uint64
	Time    time.Time

	// prev block info
	LastBlockID BlockID

	// hashes of block data
	// commit info from validators from the last block
	LastCommitHash []byte
	// transactions
	DataHash []byte

	// hashes from the app output form the preb block
	// validators for the current block
	ValidatorsHash []byte
	// validators for the next block
	NextValidatorsHash []byte
	// consensus params for the current block
	ConsensusHash []byte
	// state afterx txs from the previous block
	AppHash []byte
	// root hash of all results from the txs from the previous block
	LastResultsHash []byte

	// consensus info
	// evidence included in the block
	EvidenceHash []byte
	//original proposer of the block
	ProposerAddress []byte
}

const (
	// BlockProtocol versions all block data structures and processing.
	// This includes validity of blocks and state updates.
	BlockProtocol uint64 = 11
	AddressSize          = 20
	// MaxSignatureSize is a maximum allowed signature size for the Proposal
	// and Vote.
	// XXX: secp256k1 does not have Size nor MaxSize defined.
	MaxSignatureSize = 64
)

// ValidateBasic performs stateless validation on a Header returning an error if any
// validation fails.
//
// NOTE: Timestamp validation is subtle and handled elsewhere.
func (h Header) ValidateBasic() error {
	if h.Version.Block != BlockProtocol {
		return ufmt.Errorf("block protocol is incorrect: got: %d, want: %d ", h.Version.Block, BlockProtocol)
	}
	if len(h.ChainID) > MaxChainIDLen {
		return ufmt.Errorf("chainID is too long; got: %d, max: %d", len(h.ChainID), MaxChainIDLen)
	}

	if h.Height == 0 {
		return errors.New("zero Height")
	}

	if err := h.LastBlockID.ValidateBasic(); err != nil {
		return ufmt.Errorf("wrong LastBlockID: %v", err)
	}

	if err := validateHash(h.LastCommitHash); err != nil {
		return ufmt.Errorf("wrong LastCommitHash: %v", err)
	}

	if err := validateHash(h.DataHash); err != nil {
		return ufmt.Errorf("wrong DataHash: %v", err)
	}

	if err := validateHash(h.EvidenceHash); err != nil {
		return ufmt.Errorf("wrong EvidenceHash: %v", err)
	}

	if len(h.ProposerAddress) != AddressSize {
		return ufmt.Errorf(
			"invalid ProposerAddress length; got: %d, expected: %d",
			len(h.ProposerAddress), AddressSize,
		)
	}

	// Basic validation of hashes related to application data.
	// Will validate fully against state in state#ValidateBlock.
	if err := validateHash(h.ValidatorsHash); err != nil {
		return ufmt.Errorf("wrong ValidatorsHash: %v", err)
	}
	if err := validateHash(h.NextValidatorsHash); err != nil {
		return ufmt.Errorf("wrong NextValidatorsHash: %v", err)
	}
	if err := validateHash(h.ConsensusHash); err != nil {
		return ufmt.Errorf("wrong ConsensusHash: %v", err)
	}
	// NOTE: AppHash is arbitrary length
	if err := validateHash(h.LastResultsHash); err != nil {
		return ufmt.Errorf("wrong LastResultsHash: %v", err)
	}

	return nil
}

func (h *Header) Hash() []byte {
	if h == nil || len(h.ValidatorsHash) == 0 {
		return nil
	}
	var vbz []byte
	if h.Version.App != 0 {
		vbz = proto.AppendVarint(vbz, 1, uint64(h.Version.App))
	}
	if h.Version.Block != 0 {
		vbz = proto.AppendVarint(vbz, 2, uint64(h.Version.Block))
	}
	tbz := proto.TimeMarshal(h.Time)
	bbz := h.LastBlockID.ProtoMarshal()

	_, _ = tbz, bbz
	/*
		return merkle.HashFromByteSlices([][]byte{
			hbz,
			cdcEncode(h.ChainID),
			cdcEncode(h.Height),
			pbt,
			bzbi,
			cdcEncode(h.LastCommitHash),
			cdcEncode(h.DataHash),
			cdcEncode(h.ValidatorsHash),
			cdcEncode(h.NextValidatorsHash),
			cdcEncode(h.ConsensusHash),
			cdcEncode(h.AppHash),
			cdcEncode(h.LastResultsHash),
			cdcEncode(h.EvidenceHash),
			cdcEncode(h.ProposerAddress),
		})
	*/

	return nil
}

func (h Header) Expired(trustingPeriod time.Duration) error {
	var (
		expirationTime = h.Time.Add(trustingPeriod)
		now            = time.Now()
	)
	if !expirationTime.After(now) {
		return ufmt.Errorf("header %d has expired at %v (now: %v)", h.Height, expirationTime, now)
	}
	return nil
}

// Commit contains the evidence that a block was committed by a set of validators.
type Commit struct {
	Height     uint64
	Round      int32
	BlockID    BlockID
	Signatures []CommitSig
}

// BytesToSign returns the bytes-to-sign for a validator's vote.
// These bytes are produced from a protobuf marshaled type [CanonicalVote][1].
// Since proto is not available in Gno, the function tries to generate these
// bytes manually, using the same logic as protobuf.
//
// [1]: https://buf.build/tendermint/tendermint/docs/main:tendermint.types#tendermint.types.CanonicalVote
func (c *Commit) BytesToSign(chainID string, valIdx int) []byte {
	var buf []byte

	// Field 1: type (SignedMsgType - varint)
	buf = proto.AppendVarint(buf, 1, 2) // type precommit

	// Field 2: height (sfixed64 - fixed64)
	buf = proto.AppendFixed64(buf, 2, uint64(c.Height))

	// Field 3: round (sfixed64 - fixed64)
	buf = proto.AppendFixed64(buf, 3, uint64(c.Round))

	// Field 4: block_id (CanonicalBlockID - length-delimited)
	if c.Signatures[valIdx].BlockIDFlag == BlockIDFlagCommit {
		buf = proto.AppendLengthDelimited(buf, 4, c.BlockID.ProtoMarshal())
	}

	// Field 5: timestamp (google.protobuf.Timestamp - length-delimited)
	buf = proto.AppendTime(buf, 5, c.Signatures[valIdx].Timestamp)

	// Field 6: chain_id (string - length-delimited)
	buf = proto.AppendLengthDelimited(buf, 6, []byte(chainID))

	// Prefix with total length
	length := len(buf)
	buf = append(binary.AppendUvarint(nil, uint64(length)), buf...)

	return buf
}

// ValidateBasic performs basic validation that doesn't involve state data.
// Does not actually check the cryptographic signatures.
func (c *Commit) ValidateBasic() error {
	if c.Round < 0 {
		return errors.New("negative Round")
	}

	if c.Height >= 1 {
		if c.BlockID.IsZero() {
			return errors.New("commit cannot be for nil block")
		}

		if len(c.Signatures) == 0 {
			return errors.New("no signatures in commit")
		}
		for i, commitSig := range c.Signatures {
			if err := commitSig.ValidateBasic(); err != nil {
				return ufmt.Errorf("wrong CommitSig #%d: %v", i, err)
			}
		}
	}
	return nil
}

// CommitSig is a part of the Vote included in a Commit.
type CommitSig struct {
	BlockIDFlag      BlockIDFlag
	ValidatorAddress []byte
	Timestamp        time.Time
	Signature        []byte
}

// ValidateBasic performs basic validation.
func (cs CommitSig) ValidateBasic() error {
	switch cs.BlockIDFlag {
	case BlockIDFlagAbsent:
	case BlockIDFlagCommit:
	case BlockIDFlagNil:
	default:
		return ufmt.Errorf("unknown BlockIDFlag: %v", cs.BlockIDFlag)
	}

	switch cs.BlockIDFlag {
	case BlockIDFlagAbsent:
		if len(cs.ValidatorAddress) != 0 {
			return errors.New("validator address is present")
		}
		if !cs.Timestamp.IsZero() {
			return errors.New("time is present")
		}
		if len(cs.Signature) != 0 {
			return errors.New("signature is present")
		}
	default:
		if len(cs.ValidatorAddress) != AddressSize {
			return ufmt.Errorf("expected ValidatorAddress size to be %d bytes, got %d bytes",
				AddressSize,
				len(cs.ValidatorAddress),
			)
		}
		// NOTE: Timestamp validation is subtle and handled elsewhere.
		if len(cs.Signature) == 0 {
			return errors.New("signature is missing")
		}
		if len(cs.Signature) > MaxSignatureSize {
			return ufmt.Errorf("signature is too big (max: %d)", MaxSignatureSize)
		}
	}

	return nil
}

// BlockIdFlag indicates which BlockID the signature is for
type BlockIDFlag byte

const (
	BlockIDFlagUnknown BlockIDFlag = 0
	BlockIDFlagAbsent  BlockIDFlag = 1
	BlockIDFlagCommit  BlockIDFlag = 2
	BlockIDFlagNil     BlockIDFlag = 3
)

// BlockID
type BlockID struct {
	Hash          []byte
	PartSetHeader PartSetHeader
}

// Equals returns true if the BlockID matches the given BlockID
func (blockID BlockID) Equals(other BlockID) bool {
	return bytes.Equal(blockID.Hash, other.Hash) &&
		blockID.PartSetHeader.Equals(other.PartSetHeader)
}

// IsZero returns true if this is the BlockID of a nil block.
func (blockID BlockID) IsZero() bool {
	return len(blockID.Hash) == 0 &&
		blockID.PartSetHeader.IsZero()
}

// ValidateBasic performs basic validation.
func (blockID BlockID) ValidateBasic() error {
	// Hash can be empty in case of POLBlockID in Proposal.
	if err := validateHash(blockID.Hash); err != nil {
		return ufmt.Errorf("wrong blockID Hash: %v", err)
	}
	if err := blockID.PartSetHeader.ValidateBasic(); err != nil {
		return ufmt.Errorf("wrong PartSetHeader: %v", err)
	}
	return nil
}

func (b BlockID) ProtoMarshal() (bz []byte) {
	if len(b.Hash) > 0 {
		bz = proto.AppendLengthDelimited(bz, 1, b.Hash)
	}
	bz = proto.AppendLengthDelimited(bz, 2, b.PartSetHeader.ProtoMarshal())
	return bz
}

// PartsetHeader
type PartSetHeader struct {
	Total uint32
	Hash  []byte
}

func (psh PartSetHeader) IsZero() bool {
	return psh.Total == 0 && len(psh.Hash) == 0
}

func (psh PartSetHeader) Equals(other PartSetHeader) bool {
	return psh.Total == other.Total && bytes.Equal(psh.Hash, other.Hash)
}

// ValidateBasic performs basic validation.
func (psh PartSetHeader) ValidateBasic() error {
	// Hash can be empty in case of POLBlockID.PartSetHeader in Proposal.
	if err := validateHash(psh.Hash); err != nil {
		return ufmt.Errorf("wrong parSetHeader Hash: %v", err)
	}
	return nil
}

func (psh PartSetHeader) ProtoMarshal() (bz []byte) {
	if psh.Total > 0 {
		bz = proto.AppendVarint(bz, 1, uint64(psh.Total))
	}
	if len(psh.Hash) > 0 {
		bz = proto.AppendLengthDelimited(bz, 2, psh.Hash)
	}
	return bz
}

// Consensus captures the consensus rules for processing a block in the blockchain,
// including all blockchain data structures and the rules of the application's
// state transition machine.
type Consensus struct {
	Block uint64
	App   uint64
}
