// Package arc is an IBC light client of Circle's Arc for gno.land.
//
// Arc is an EVM chain whose blocks are decided by Malachite, a Tendermint
// BFT engine: a block is final once more than 2/3 of the validators'
// voting power signed a precommit for it, and the commit certificate of
// those signatures is final forever. The client is a variant of the
// Tendermint light client (07-tendermint) with three differences:
//
//   - a precommit signs the SSZ encoding of Arc's Vote with Ed25519, over
//     the block's execution hash, with no chain id (certificate.gno);
//   - the validator set is not in the header but in the ValidatorRegistry's
//     storage: the set signing H+1 is the one the state after H holds, so an
//     update proves a block B with the certificate of its child B+1 and
//     reads the set that signed it from B's state, with Merkle-Patricia
//     proofs into B's state root, or knows it is unchanged when the
//     registry's storage root is (header.gno, registry.gno);
//   - the block is the EVM header itself, hashed with Keccak-256, so the
//     state root that packet proofs open is one the certificates commit to.
//
// See docs/adrs/0006-arc-light-client.md.
//
// Packet commitments are proven as on Ethereum: eth_getProof storage proofs
// of the ICS26 router's commitments mapping, in the Ext field of packet
// messages (extproof), checked by the Ethereum client's code.
package arc

import (
	"bytes"
	"encoding/hex"
	"errors"
	"strconv"
	"time"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/ics23/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Version names this verifier package and version.
const Version = "arc/v0"

// ArcLightClient is the light client. Consensus states are keyed by the
// height {0, block number}.
type ArcLightClient struct {
	ClientState            *ClientState
	ConsensusStateByHeight *bptree.BPTree // height:*ConsensusState
	// TrustedFromHeight is the height of the consensus state a recovery
	// copied: the states below it were trusted by the client state the
	// recovery replaced, and are never read again.
	TrustedFromHeight uint64
}

var (
	_ lightclient.Interface = (*ArcLightClient)(nil)
	_ extproof.Verifier     = (*ArcLightClient)(nil)
)

// NewArcLightClient is an uninitialized client.
func NewArcLightClient() *ArcLightClient {
	return &ArcLightClient{ConsensusStateByHeight: bptree.NewBPTree32()}
}

// NewLightClient is NewArcLightClient typed as the generic interface, for the
// IBC core's client constructor table.
func NewLightClient() lightclient.Interface { return NewArcLightClient() }

func heightAt(n uint64) types.Height { return types.NewHeight(0, n) }

// VerifierVersion names this verifier.
func (c *ArcLightClient) VerifierVersion() string { return Version }

// Arc is the v0 verifier itself, for renders.
func (c *ArcLightClient) Arc() *ArcLightClient { return c }

// RouteIdentity is the history this verifier authenticates: the Arc chain
// (its chain id and validator registry), the ICS26 router and its
// commitments slot, all fixed at creation.
func (c *ArcLightClient) RouteIdentity() (identity, router string) {
	cs := c.ClientState
	router = "0x" + hex.EncodeToString(cs.IBCContractAddress)
	identity = "arc chain " + strconv.FormatUint(cs.ChainID, 10) +
		", registry 0x" + hex.EncodeToString(cs.RegistryAddress) +
		", router " + router +
		", commitment slot 0x" + hex.EncodeToString(cs.IBCCommitmentSlot)
	return identity, router
}

// Initialize implements lightclient.Interface. It runs once.
func (c *ArcLightClient) Initialize(clientState lightclient.ClientState, consensusState lightclient.ConsensusState) error {
	if c.ClientState != nil {
		return errors.New("arc client initialized already")
	}
	cs, ok := clientState.(ClientState)
	if !ok {
		return ufmt.Errorf("expected arc ClientState, got %T", clientState)
	}
	in, ok := consensusState.(ConsensusState)
	if !ok {
		return ufmt.Errorf("expected arc ConsensusState, got %T", consensusState)
	}
	if in.Height != cs.LatestHeight {
		return ufmt.Errorf("consensus state height %d differs from client latest height %d", in.Height, cs.LatestHeight)
	}
	// Copy into values allocated here: the caller's realm keeps owning its
	// own slices and could change them after creation.
	copied := cs.clone()
	c.ClientState = &copied
	cons := copyConsensusState(in)
	cons.NextValidators = copyValidatorSet(in.NextValidators)
	c.setConsensusState(&cons)
	return nil
}

func copyValidatorSet(in *ValidatorSet) *ValidatorSet {
	out := &ValidatorSet{TotalPower: in.TotalPower, Validators: make([]Validator, len(in.Validators))}
	for i, v := range in.Validators {
		out.Validators[i] = Validator{Address: cloneBytes(v.Address), PubKey: cloneBytes(v.PubKey), Power: v.Power}
	}
	return out
}

func now() uint64 { return uint64(time.Now().Unix()) }

// VerifyClientMessage implements lightclient.Interface.
func (c *ArcLightClient) VerifyClientMessage(clientMsg lightclient.ClientMessage) error {
	switch msg := clientMsg.(type) {
	case *Header:
		_, err := c.verifyHeader(msg)
		return err
	case *Misbehaviour:
		return c.verifyMisbehaviour(msg)
	}
	return errors.New("unknown client message type")
}

// checkLatestAnchor requires a client message to build on the latest trusted
// state, of a client that has not expired: an older trusted set, possibly
// rotated out and no longer accountable, must not insert blocks below the
// latest or freeze the client.
func (c *ArcLightClient) checkLatestAnchor(trustedHeight uint64) (*ConsensusState, error) {
	cs := c.ClientState
	if trustedHeight != cs.LatestHeight {
		return nil, ufmt.Errorf("updates must build on the latest trusted height %d, not %d", cs.LatestHeight, trustedHeight)
	}
	trusted, ok := c.GetConsensusState(heightAt(trustedHeight))
	if !ok {
		return nil, ufmt.Errorf("no consensus state at trusted height %d", trustedHeight)
	}
	if c.expired(trusted) {
		return nil, ufmt.Errorf("client expired: its latest trusted block is more than %d seconds old", cs.TrustingPeriod)
	}
	return trusted, nil
}

func (c *ArcLightClient) expired(latest *ConsensusState) bool {
	t := now()
	return t >= latest.Timestamp && t-latest.Timestamp >= c.ClientState.TrustingPeriod
}

// derive checks everything a header proves except the certificate's
// signatures: C by its hash, B as C's parent, the set B's state holds.
// sameSet reports whether that set, which signed C, is the trusted one.
func (c *ArcLightClient) derive(trusted *ConsensusState, h *Header) (b block, sameSet bool, err error) {
	if err := h.ValidateBasic(); err != nil {
		return block{}, false, err
	}
	cs := c.ClientState
	cert := h.Certificate
	certified, hash, err := ethereum.DecodeExecutionHeader(h.CertifiedHeader)
	if err != nil {
		return block{}, false, ufmt.Errorf("certified header: %v", err)
	}
	if !bytes.Equal(hash, cert.BlockHash) {
		return block{}, false, errors.New("certified header hash differs from the certificate's block hash")
	}
	if certified.BlockNumber != cert.Height {
		return block{}, false, ufmt.Errorf("certified header number %d differs from the certificate height %d", certified.BlockNumber, cert.Height)
	}
	b, err = readBlock(cs, h.BlockHeader, h.RegistryProof, h.SetNodes, trusted.RegistryStorageRoot, trusted.NextValidators)
	if err != nil {
		return block{}, false, err
	}
	if !bytes.Equal(b.hash, certified.ParentHash) || b.exec.BlockNumber != h.height() {
		return block{}, false, errors.New("block header is not the certified block's parent")
	}
	if b.exec.Timestamp < trusted.Timestamp {
		return block{}, false, errors.New("block timestamp precedes the trusted block's")
	}
	if b.exec.Timestamp > now()+cs.MaxClockDrift {
		return block{}, false, errors.New("block timestamp is in the future")
	}
	return b, b.nextValidators == trusted.NextValidators, nil
}

// verifyHeader verifies h from the latest trusted state: more than 2/3 of
// the set that signed C (B's registry set) signed its certificate and, when
// that set is not the trusted one, more than the trust level of the trusted
// set did too (Tendermint's skipping verification).
func (c *ArcLightClient) verifyHeader(h *Header) (block, error) {
	trusted, err := c.checkLatestAnchor(h.TrustedHeight)
	if err != nil {
		return block{}, err
	}
	b, sameSet, err := c.derive(trusted, h)
	if err != nil {
		return block{}, err
	}
	var trustedSet *ValidatorSet
	if !sameSet {
		trustedSet = trusted.NextValidators
	}
	// Last, as in Tendermint: the set comes from the message's proofs.
	if err := h.Certificate.verify(b.nextValidators, trustedSet, c.ClientState.TrustLevel); err != nil {
		return block{}, err
	}
	h.remember(&b, trusted)
	return b, nil
}

func (c *ArcLightClient) verifyMisbehaviour(m *Misbehaviour) error {
	if err := m.ValidateBasic(); err != nil {
		return err
	}
	if _, err := c.verifyHeader(m.Header1); err != nil {
		return ufmt.Errorf("header 1: %v", err)
	}
	if _, err := c.verifyHeader(m.Header2); err != nil {
		return ufmt.Errorf("header 2: %v", err)
	}
	return nil
}

// CheckForMisbehaviour implements lightclient.Interface. A header builds on
// the latest height and so lands above every stored one: only a
// Misbehaviour is evidence.
func (c *ArcLightClient) CheckForMisbehaviour(clientMsg lightclient.ClientMessage) bool {
	_, ok := clientMsg.(*Misbehaviour)
	return ok
}

// UpdateStateOnMisbehaviour implements lightclient.Interface.
func (c *ArcLightClient) UpdateStateOnMisbehaviour(lightclient.ClientMessage) {
	cs := *c.ClientState
	cs.IsFrozen = true
	c.ClientState = &cs
}

// UpdateState implements lightclient.Interface. The header was verified by
// VerifyClientMessage, which kept what it derived on the header; a header
// verified from another trusted state (or never) is derived again, without
// the signatures.
func (c *ArcLightClient) UpdateState(clientMsg lightclient.ClientMessage) []types.Height {
	h, ok := clientMsg.(*Header)
	if !ok {
		panic(ufmt.Sprintf("expected *arc.Header, got %T", clientMsg))
	}
	trusted, ok := c.GetConsensusState(heightAt(h.TrustedHeight))
	if !ok {
		panic("trusted consensus state disappeared")
	}
	var b block
	if h.verified != nil && h.verifiedFrom == trusted {
		b = *h.verified
	} else {
		var err error
		if b, _, err = c.derive(trusted, h); err != nil {
			panic(err) // checked by VerifyClientMessage
		}
	}
	cons := b.consensusState()
	cons = copyConsensusState(cons)
	if cons.NextValidators != trusted.NextValidators {
		cons.NextValidators = copyValidatorSet(cons.NextValidators)
	}
	c.setConsensusState(&cons)
	updated := *c.ClientState
	updated.LatestHeight = cons.Height
	c.ClientState = &updated
	return []types.Height{heightAt(cons.Height)}
}

// VerifyMembership implements lightclient.Interface. This client's proofs are
// not ICS23 proofs: relayers pass an ethereum.MembershipProof in the
// message's Ext field, which reaches VerifyMembershipProof.
func (c *ArcLightClient) VerifyMembership(types.Height, []ics23.CommitmentProof, types.MerklePath, []byte) error {
	return errors.New("arc light client proofs must be passed as an extproof.Proof")
}

// VerifyNonMembership implements lightclient.Interface; see VerifyMembership.
func (c *ArcLightClient) VerifyNonMembership(types.Height, []ics23.CommitmentProof, types.MerklePath) error {
	return errors.New("arc light client proofs must be passed as an extproof.Proof")
}

// VerifyMembershipProof implements extproof.Verifier: value must be the
// 32-byte value of the ICS26 commitment at path.
func (c *ArcLightClient) VerifyMembershipProof(height types.Height, proof any, path types.MerklePath, value []byte) error {
	if value == nil {
		value = []byte{}
	}
	stored, err := c.ProvenValue(height, proof, path)
	if err != nil {
		return err
	}
	return ethereum.CheckCommitment(stored, value)
}

// VerifyNonMembershipProof implements extproof.Verifier.
func (c *ArcLightClient) VerifyNonMembershipProof(height types.Height, proof any, path types.MerklePath) error {
	stored, err := c.ProvenValue(height, proof, path)
	if err != nil {
		return err
	}
	return ethereum.CheckCommitment(stored, nil)
}

// ProvenValue is the value proof establishes for the router's commitment at
// path at height, zero (32 zero bytes) if none is stored.
func (c *ArcLightClient) ProvenValue(height types.Height, proof any, path types.MerklePath) ([]byte, error) {
	mp, err := ethereum.AsMembershipProof(proof)
	if err != nil {
		return nil, err
	}
	if height.RevisionNumber != 0 {
		return nil, ufmt.Errorf("revision number must be 0, got %d", height.RevisionNumber)
	}
	if height.RevisionHeight > c.ClientState.LatestHeight {
		return nil, ufmt.Errorf("proof height %d is after the latest height %d", height.RevisionHeight, c.ClientState.LatestHeight)
	}
	cons, ok := c.GetConsensusState(height)
	if !ok {
		return nil, ufmt.Errorf("no consensus state at height %d", height.RevisionHeight)
	}
	return ethereum.RouterCommitment(cons.StateRoot, c.ClientState.IBCContractAddress, c.ClientState.IBCCommitmentSlot, mp, path)
}

// Status implements lightclient.Interface. The client expires TrustingPeriod
// seconds after its latest trusted block and must then be recovered.
func (c *ArcLightClient) Status() lightclient.Status {
	if c.ClientState.IsFrozen {
		return lightclient.Frozen
	}
	latest, ok := c.GetConsensusState(c.LatestHeight())
	if !ok || c.expired(latest) {
		return lightclient.Expired
	}
	return lightclient.Active
}

// LatestHeight implements lightclient.Interface.
func (c *ArcLightClient) LatestHeight() types.Height { return heightAt(c.ClientState.LatestHeight) }

// TimestampAtHeight implements lightclient.Interface: the block time, in
// seconds.
func (c *ArcLightClient) TimestampAtHeight(height types.Height) (uint64, error) {
	cons, ok := c.GetConsensusState(height)
	if !ok {
		return 0, ufmt.Errorf("no consensus state at height %s", height.String())
	}
	return cons.Timestamp, nil
}

// RecoverClient implements lightclient.Interface: the substitute must track
// the same chain, registry and router and be ahead; its latest consensus
// state, trust parameters and registry implementation are adopted (the way
// past a registry upgrade the subject refused) and the subject unfrozen.
func (c *ArcLightClient) RecoverClient(substitute lightclient.Interface) error {
	if err := c.CheckRecovery(substitute); err != nil {
		return err
	}
	sub := substitute.(*ArcLightClient)
	cons, _ := sub.GetConsensusState(sub.LatestHeight())
	copied := copyConsensusState(*cons)
	copied.NextValidators = copyValidatorSet(cons.NextValidators)
	c.setConsensusState(&copied)
	updated := *c.ClientState
	b := sub.ClientState
	updated.LatestHeight = b.LatestHeight
	updated.TrustingPeriod, updated.MaxClockDrift, updated.TrustLevel = b.TrustingPeriod, b.MaxClockDrift, b.TrustLevel
	updated.RegistryImplementation = cloneBytes(b.RegistryImplementation)
	updated.RegistryStorageLocation = cloneBytes(b.RegistryStorageLocation)
	updated.IsFrozen = false
	c.ClientState = &updated
	c.TrustedFromHeight = copied.Height
	return nil
}

// CheckRecovery is why RecoverClient would refuse substitute, or nil.
func (c *ArcLightClient) CheckRecovery(substitute lightclient.Interface) error {
	sub, ok := substitute.(*ArcLightClient)
	if !ok {
		return ufmt.Errorf("substitute must be an arc client, got %T", substitute)
	}
	a, b := c.ClientState, sub.ClientState
	// The registry's implementation and storage location may differ: a
	// recovery is how the client follows a registry upgrade that moved them.
	if a.ChainID != b.ChainID || !bytes.Equal(a.RegistryAddress, b.RegistryAddress) ||
		!bytes.Equal(a.IBCContractAddress, b.IBCContractAddress) || !bytes.Equal(a.IBCCommitmentSlot, b.IBCCommitmentSlot) {
		return errors.New("substitute client tracks a different chain, registry or router")
	}
	if b.LatestHeight <= a.LatestHeight {
		return errors.New("substitute must be ahead of the subject")
	}
	if _, ok := sub.GetConsensusState(sub.LatestHeight()); !ok {
		return errors.New("substitute has no latest consensus state")
	}
	return nil
}

// VerifyUpgradeAndUpdateState implements lightclient.Interface. Arc has no
// IBC upgrade path; replace the client with RecoverClient instead.
func (c *ArcLightClient) VerifyUpgradeAndUpdateState(_, _, _, _ any) error {
	return errors.New("the arc light client does not support upgrades")
}

func (c *ArcLightClient) setConsensusState(cons *ConsensusState) {
	c.ConsensusStateByHeight.Set(heightAt(cons.Height).StringNatSort(), cons)
}

// GetConsensusState returns the consensus state at height, if any and still
// trusted.
func (c *ArcLightClient) GetConsensusState(height types.Height) (*ConsensusState, bool) {
	if height.RevisionNumber != 0 || height.RevisionHeight < c.TrustedFromHeight {
		return nil, false
	}
	v := c.ConsensusStateByHeight.Get(height.StringNatSort())
	if v == nil {
		return nil, false
	}
	return v.(*ConsensusState), true
}
