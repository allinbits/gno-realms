package ethereum

import (
	"bytes"
	"errors"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The functions below expose this client's EVM proof verification to the
// light clients of other EVM chains running the same ICS26 router (the Arc
// client): how a router commitment is proven from an execution state root
// does not depend on the consensus that finalized the root.

// ExecutionHeader is what a light client keeps of an RLP execution block
// header.
type ExecutionHeader struct {
	ParentHash  []byte
	StateRoot   []byte
	BlockNumber uint64
	Timestamp   uint64
}

// DecodeExecutionHeader reads the parent hash, state root, block number and
// timestamp of an RLP-encoded execution block header, and returns its hash,
// Keccak256(rlp).
func DecodeExecutionHeader(rlp []byte) (ExecutionHeader, []byte, error) {
	e, err := decodeExecutionHeader(rlp)
	if err != nil {
		return ExecutionHeader{}, nil, err
	}
	item, _ := rlpDecode(rlp) // decoded above
	fields, _ := rlpList(item)
	if fields[0].isList || len(fields[0].payload) != hashSize {
		return ExecutionHeader{}, nil, errors.New("invalid execution header parent hash")
	}
	return ExecutionHeader{
		ParentHash: fields[0].payload, StateRoot: e.stateRoot,
		BlockNumber: e.blockNumber, Timestamp: e.timestamp,
	}, keccak(rlp), nil
}

// Keccak256 is the Keccak-256 hash of b.
func Keccak256(b []byte) []byte { return keccak(b) }

// AsMembershipProof reads proof, a MembershipProof or a non-nil pointer to
// one.
func AsMembershipProof(proof any) (MembershipProof, error) {
	switch p := proof.(type) {
	case MembershipProof:
		return p, nil
	case *MembershipProof:
		if p == nil {
			return MembershipProof{}, errors.New("nil membership proof")
		}
		return *p, nil
	}
	return MembershipProof{}, ufmt.Errorf("expected ethereum.MembershipProof, got %T", proof)
}

// RouterCommitment is the value of commitments[keccak256(path)] in the ICS26
// router at router, whose commitments mapping is at mappingSlot, in the
// state with root stateRoot, zero (32 zero bytes) if unset, as established
// by proof.
func RouterCommitment(stateRoot, router, mappingSlot []byte, proof MembershipProof, path types.MerklePath) ([]byte, error) {
	if len(path.KeyPath) != 1 {
		return nil, ufmt.Errorf("path must have exactly one element, got %d", len(path.KeyPath))
	}
	storageRoot, err := accountStorageRoot(stateRoot, router, proof.AccountProof)
	if err != nil {
		return nil, ufmt.Errorf("account proof: %v", err)
	}
	v, err := storageValue(storageRoot, commitmentStorageSlot(path.KeyPath[0], mappingSlot), proof.StorageProof)
	if err != nil {
		return nil, ufmt.Errorf("storage proof: %v", err)
	}
	return v, nil
}

// CheckCommitment compares a proven router commitment with value, the
// expected 32 bytes, or with zero when value is nil (non-membership).
func CheckCommitment(stored, value []byte) error {
	if value == nil {
		if !bytes.Equal(stored, make([]byte, hashSize)) {
			return errors.New("a commitment is stored at the path")
		}
		return nil
	}
	if len(value) != hashSize {
		return ufmt.Errorf("commitment value must be 32 bytes, got %d", len(value))
	}
	if !bytes.Equal(stored, value) {
		return errors.New("stored commitment differs from the expected value")
	}
	return nil
}

// AccountStorageRoot is the storage root of the account at address in the
// state with root stateRoot, as eth_getProof's accountProof establishes.
func AccountStorageRoot(stateRoot, address []byte, proof [][]byte) ([]byte, error) {
	return accountStorageRoot(stateRoot, address, proof)
}

// StorageReader reads slots of one storage trie from a pool of proof nodes:
// the union of eth_getProof's storage proofs of every slot read, each node
// once.
type StorageReader struct {
	root  []byte
	nodes *nodePool
}

// NewStorageReader indexes nodes for reads under storageRoot.
func NewStorageReader(storageRoot []byte, nodes [][]byte) *StorageReader {
	return &StorageReader{root: storageRoot, nodes: newNodePool(nodes)}
}

// Get is the 32-byte value of slot, zero when the proof shows it unset. An
// error means the pool does not establish either.
func (r *StorageReader) Get(slot []byte) ([]byte, error) {
	return storageValueIn(r.nodes, r.root, slot)
}
