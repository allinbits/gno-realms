package arc

import (
	"bytes"
	"errors"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Header moves the client from its latest trusted block T to a later block
// B, the parent of a certified block C:
//
//   - C's commit certificate is checked, C's header hashed to the
//     certificate's block hash, and B's header hashed to C's parent hash: a
//     certified block's parent is final, as every ancestor of a final block
//     is;
//   - the set that signed C is the registry's in the state after B (the
//     consensus layer reads the set for a height from the state after the
//     height before), proven by Merkle-Patricia proofs into B's state root;
//     the same set is the one B's consensus state records as the signers of
//     the block after it.
//
// Every proof of an update is into one state, B's: Arc's public RPC nodes
// serve eth_getProof for the latest block only, and the relayer reads B's
// registry and packet proofs while B is the latest, then waits for C.
type Header struct {
	// TrustedHeight is T, the client's latest height.
	TrustedHeight uint64
	// Certificate certifies C, whose RLP header is CertifiedHeader.
	Certificate     Certificate
	CertifiedHeader []byte
	// BlockHeader is B's RLP header, which C's parent hash names.
	BlockHeader []byte
	// RegistryProof is the registry's account proof in B's state, and
	// SetNodes the storage nodes of the set it holds: empty when the
	// registry's storage root equals the trusted block's.
	RegistryProof [][]byte
	SetNodes      [][]byte

	// verified is what VerifyClientMessage derived from the header against
	// the trusted state verifiedFrom, so that UpdateState, which the core
	// calls next with the same header, does not read the proofs again.
	// Unexported: only this package sets it, and only after a verification
	// passed.
	verified     *block
	verifiedFrom *ConsensusState
}

// ClientType implements lightclient.ClientMessage.
func (*Header) ClientType() string { return ClientType }

// remember keeps what a verification derived. A method: the core receives
// the header from the relaying realm readonly, which forbids writing its
// fields directly but not through its own methods.
func (h *Header) remember(b *block, from *ConsensusState) {
	h.verified, h.verifiedFrom = b, from
}

// ValidateBasic implements lightclient.ClientMessage.
func (h *Header) ValidateBasic() error {
	if err := h.Certificate.validateBasic(); err != nil {
		return err
	}
	if h.Certificate.Height <= h.TrustedHeight+1 {
		return errors.New("the certified block must be at least two blocks after the trusted one")
	}
	if len(h.CertifiedHeader) == 0 || len(h.BlockHeader) == 0 {
		return errors.New("missing block headers")
	}
	if len(h.RegistryProof) == 0 {
		return errors.New("missing registry proof")
	}
	return nil
}

// height is the height of the block h proves, B.
func (h *Header) height() uint64 { return h.Certificate.Height - 1 }

// Misbehaviour is two headers proving different blocks at one height, both
// verifying from the client's latest trusted state.
type Misbehaviour struct {
	Header1 *Header
	Header2 *Header
}

// ClientType implements lightclient.ClientMessage.
func (*Misbehaviour) ClientType() string { return ClientType }

// ValidateBasic implements lightclient.ClientMessage.
func (m *Misbehaviour) ValidateBasic() error {
	if m.Header1 == nil || m.Header2 == nil {
		return errors.New("misbehaviour needs two headers")
	}
	if err := m.Header1.ValidateBasic(); err != nil {
		return ufmt.Errorf("header 1: %v", err)
	}
	if err := m.Header2.ValidateBasic(); err != nil {
		return ufmt.Errorf("header 2: %v", err)
	}
	if m.Header1.height() != m.Header2.height() {
		return errors.New("misbehaviour headers prove different heights")
	}
	if bytes.Equal(m.Header1.BlockHeader, m.Header2.BlockHeader) {
		return errors.New("misbehaviour headers prove the same block")
	}
	return nil
}

// block is what the client keeps of a proven block B.
type block struct {
	exec           ethereum.ExecutionHeader
	hash           []byte
	registryRoot   []byte
	nextValidators *ValidatorSet
	implementation []byte
}

func (b block) consensusState() ConsensusState {
	return ConsensusState{
		Height: b.exec.BlockNumber, Timestamp: b.exec.Timestamp, BlockHash: b.hash,
		StateRoot: b.exec.StateRoot, RegistryStorageRoot: b.registryRoot, NextValidators: b.nextValidators,
	}
}

// readBlock decodes B's header and reads the validator set its state holds,
// knownSet when the registry's storage root is known.
func readBlock(cs *ClientState, header []byte, accountProof, nodes [][]byte, known []byte, knownSet *ValidatorSet) (block, error) {
	exec, hash, err := ethereum.DecodeExecutionHeader(header)
	if err != nil {
		return block{}, ufmt.Errorf("block header: %v", err)
	}
	root, set, impl, err := registryState(cs, exec.StateRoot, accountProof, nodes, known, knownSet)
	if err != nil {
		return block{}, err
	}
	return block{exec: exec, hash: hash, registryRoot: root, nextValidators: set, implementation: impl}, nil
}

// NewClientStates completes cs (its latest height and registry
// implementation) and builds the consensus state of a block from its RLP
// header and the registry's proofs in its state (accountProof, and
// setNodes for the set it holds, the implementation slot included): what a
// client is created with. Only the block itself is trusted, by its hash: a
// creator trusts it as any IBC client's creator trusts its initial state.
func NewClientStates(cs ClientState, header []byte, accountProof, setNodes [][]byte) (ClientState, ConsensusState, error) {
	cs.RegistryImplementation = nil
	b, err := readBlock(&cs, header, accountProof, setNodes, nil, nil)
	if err != nil {
		return ClientState{}, ConsensusState{}, err
	}
	cs.RegistryImplementation = b.implementation
	cs.LatestHeight = b.exec.BlockNumber
	return cs, b.consensusState(), nil
}
