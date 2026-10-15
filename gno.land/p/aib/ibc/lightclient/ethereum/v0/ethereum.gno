// Package ethereum is an IBC light client of Ethereum for gno.land. It
// follows the Altair light-client sync protocol: it trusts the sync
// committee, verifies its BLS aggregate signature over each update with the
// crypto/bls12381 native, tracks finalized execution state roots, and proves
// ICS26 router commitments with Merkle-Patricia storage proofs.
//
// It ports the Ethereum light client of cosmos/solidity-ibc-eureka
// (packages/ethereum/light-client), and supports Electra and later forks.
//
// Its storage proofs are not ICS23 proofs, so it implements
// extproof.Verifier and relayers pass a MembershipProof in the Ext field of
// packet messages.
package ethereum

import (
	"errors"
	"time"

	"crypto/bls12381"

	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/ics23/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

// EthLightClient is the light client. Consensus states are keyed by the
// height {0, finalized slot}.
type EthLightClient struct {
	ClientState            *ClientState
	ConsensusStateByHeight *bptree.BPTree // height:*ConsensusState
}

var (
	_ lightclient.Interface = (*EthLightClient)(nil)
	_ extproof.Verifier     = (*EthLightClient)(nil)
)

func NewEthLightClient() *EthLightClient {
	return &EthLightClient{ConsensusStateByHeight: bptree.NewBPTree32()}
}

// NewLightClient is NewEthLightClient typed as the generic interface, for the
// IBC core's client constructor table.
func NewLightClient() lightclient.Interface {
	return NewEthLightClient()
}

func heightAtSlot(slot uint64) types.Height {
	return types.NewHeight(0, slot)
}

// Implements lightclient.Interface.
func (c *EthLightClient) Initialize(clientState lightclient.ClientState, consensusState lightclient.ConsensusState) error {
	cs, ok := clientState.(ClientState)
	if !ok {
		return ufmt.Errorf("expected ethereum ClientState, got %T", clientState)
	}
	in, ok := consensusState.(ConsensusState)
	if !ok {
		return ufmt.Errorf("expected ethereum ConsensusState, got %T", consensusState)
	}
	if in.Slot != cs.LatestSlot {
		return ufmt.Errorf("consensus state slot %d differs from client latest slot %d", in.Slot, cs.LatestSlot)
	}
	// Copy into values allocated here, see the tendermint client's Initialize.
	c.ClientState = &cs
	cons := copyConsensusState(in)
	c.setConsensusState(&cons)
	return nil
}

func copyConsensusState(in ConsensusState) ConsensusState {
	out := ConsensusState{
		Slot:                 in.Slot,
		StateRoot:            in.StateRoot,
		Timestamp:            in.Timestamp,
		CurrentSyncCommittee: in.CurrentSyncCommittee,
	}
	if in.NextSyncCommittee != nil {
		next := *in.NextSyncCommittee
		out.NextSyncCommittee = &next
	}
	return out
}

// Implements lightclient.Interface.
func (c *EthLightClient) VerifyClientMessage(clientMsg lightclient.ClientMessage) error {
	switch msg := clientMsg.(type) {
	case *Header:
		return c.verifyHeader(msg)
	case *Misbehaviour:
		return c.verifyMisbehaviour(msg)
	}
	return errors.New("unknown client message type")
}

func now() uint64 { return uint64(time.Now().Unix()) }

func (c *EthLightClient) currentSlot() (uint64, error) {
	slot, ok := c.ClientState.slotAtTimestamp(now())
	if !ok {
		return 0, errors.New("current time precedes the tracked chain's genesis")
	}
	return slot, nil
}

// trustedState returns the consensus state at slot and the full active sync
// committee, checked against that state's summary.
func (c *EthLightClient) trustedState(slot uint64, committee SyncCommittee, isNext bool) (*ConsensusState, error) {
	cons, ok := c.GetConsensusState(heightAtSlot(slot))
	if !ok {
		return nil, ufmt.Errorf("no consensus state at trusted slot %d", slot)
	}
	if err := committee.validate(c.ClientState.SyncCommitteeSize); err != nil {
		return nil, err
	}
	want := cons.CurrentSyncCommittee
	if isNext {
		if cons.NextSyncCommittee == nil {
			return nil, errors.New("next sync committee is not known")
		}
		want = *cons.NextSyncCommittee
	}
	if !committee.summarize().equal(want) {
		return nil, errors.New("active sync committee does not match the trusted one")
	}
	return cons, nil
}

// verifyHeader implements verify_header.
func (c *EthLightClient) verifyHeader(h *Header) error {
	cs := c.ClientState
	trusted, err := c.trustedState(h.TrustedSlot, h.ActiveSyncCommittee, h.ActiveIsNext)
	if err != nil {
		return err
	}
	current, err := c.currentSlot()
	if err != nil {
		return err
	}
	u := h.ConsensusUpdate
	if err := c.validateUpdate(trusted, h.ActiveSyncCommittee, h.ActiveIsNext, u, current); err != nil {
		return err
	}
	// Only a 2/3 supermajority may move the client.
	if u.SyncAggregate.participants()*3 < u.SyncAggregate.size()*2 {
		return errors.New("not enough sync committee signatures")
	}
	if u.FinalizedHeader.Beacon.Slot <= trusted.Slot {
		return ufmt.Errorf("finalized slot %d is not after trusted slot %d", u.FinalizedHeader.Beacon.Slot, trusted.Slot)
	}
	if cs.periodAtSlot(u.FinalizedHeader.Beacon.Slot) > cs.periodAtSlot(trusted.Slot) && u.NextSyncCommittee == nil {
		return errors.New("an update into the next period must carry the next sync committee")
	}
	return nil
}

// validateUpdate implements validate_light_client_update.
func (c *EthLightClient) validateUpdate(trusted *ConsensusState, committee SyncCommittee, committeeIsNext bool, u LightClientUpdate, currentSlot uint64) error {
	cs := c.ClientState
	if u.SyncAggregate.participants() < cs.MinSyncCommitteeParticipants {
		return ufmt.Errorf("insufficient sync committee participants: %d", u.SyncAggregate.participants())
	}
	if err := c.validateLightClientHeader(u.AttestedHeader); err != nil {
		return ufmt.Errorf("attested header: %v", err)
	}
	attestedSlot := u.AttestedHeader.Beacon.Slot
	finalizedSlot := u.FinalizedHeader.Beacon.Slot
	if finalizedSlot == cs.GenesisSlot {
		return errors.New("finalized slot is the genesis slot")
	}
	if currentSlot < u.SignatureSlot {
		return ufmt.Errorf("signature slot %d is after the current slot %d", u.SignatureSlot, currentSlot)
	}
	if !(u.SignatureSlot > attestedSlot && attestedSlot >= finalizedSlot) {
		return errors.New("slots must satisfy signature > attested >= finalized")
	}

	storedPeriod := cs.periodAtSlot(trusted.Slot)
	signaturePeriod := cs.periodAtSlot(u.SignatureSlot)
	// The full next committee is only available when the relayer passed it
	// as the active one; see TrustedConsensusState in the Rust client.
	nextKnown := committeeIsNext
	if nextKnown {
		if signaturePeriod != storedPeriod && signaturePeriod != storedPeriod+1 {
			return ufmt.Errorf("signature period %d is not the stored period %d or the next", signaturePeriod, storedPeriod)
		}
	} else if signaturePeriod != storedPeriod {
		return ufmt.Errorf("signature period %d is not the stored period %d", signaturePeriod, storedPeriod)
	}

	attestedPeriod := cs.periodAtSlot(attestedSlot)
	isNextCommitteeUpdate := u.NextSyncCommittee != nil
	hasNextCommittee := !nextKnown && isNextCommitteeUpdate && attestedPeriod == storedPeriod
	if !(attestedSlot > trusted.Slot || hasNextCommittee) {
		return errors.New("irrelevant update")
	}

	if err := c.validateLightClientHeader(u.FinalizedHeader); err != nil {
		return ufmt.Errorf("finalized header: %v", err)
	}
	if err := cs.verifySupportedFork(attestedSlot); err != nil {
		return err
	}
	if !isValidMerkleBranch(u.FinalizedHeader.Beacon.HashTreeRoot(), u.FinalityBranch,
		finalizedRootGindex, u.AttestedHeader.Beacon.StateRoot) {
		return errors.New("invalid finality branch")
	}

	if isNextCommitteeUpdate {
		if err := u.NextSyncCommittee.validate(cs.SyncCommitteeSize); err != nil {
			return ufmt.Errorf("next sync committee: %v", err)
		}
		if attestedPeriod == storedPeriod && nextKnown &&
			!u.NextSyncCommittee.summarize().equal(committee.summarize()) {
			return errors.New("next sync committee does not match the trusted one")
		}
		if !isValidMerkleBranch(u.NextSyncCommittee.hashTreeRoot(), u.NextSyncCommitteeBranch,
			nextSyncCommitteeGindex, u.AttestedHeader.Beacon.StateRoot) {
			return errors.New("invalid next sync committee branch")
		}
	}

	// The signing committee: the current one within the stored period, the
	// next one across it.
	if signaturePeriod == storedPeriod && committeeIsNext {
		return errors.New("update signed in the stored period needs the current sync committee")
	}
	if signaturePeriod != storedPeriod && !committeeIsNext {
		return errors.New("update signed in the next period needs the next sync committee")
	}
	if u.SyncAggregate.size() != uint64(len(committee.Pubkeys)) {
		return ufmt.Errorf("sync committee bits cover %d members, committee has %d", u.SyncAggregate.size(), len(committee.Pubkeys))
	}
	var participants []byte
	for i, pk := range committee.Pubkeys {
		if u.SyncAggregate.SyncCommitteeBits[i/8]&(1<<uint(i%8)) != 0 {
			participants = append(participants, pk...)
		}
	}

	forkVersionSlot := u.SignatureSlot
	if forkVersionSlot > 0 {
		forkVersionSlot--
	}
	forkVersion := cs.ForkParameters.forkVersion(cs.epochAtSlot(forkVersionSlot))
	domain := computeDomain(domainSyncCommittee, forkVersion, cs.GenesisValidatorsRoot)
	signingRoot := computeSigningRoot(u.AttestedHeader.Beacon.HashTreeRoot(), domain)
	if !bls12381.FastAggregateVerify(participants, signingRoot, u.SyncAggregate.SyncCommitteeSignature) {
		return errors.New("invalid sync committee signature")
	}
	return nil
}

// validateLightClientHeader implements is_valid_light_client_header for
// Electra and later: the execution payload header is in the beacon body.
func (c *EthLightClient) validateLightClientHeader(h LightClientHeader) error {
	if err := c.ClientState.verifySupportedFork(h.Beacon.Slot); err != nil {
		return err
	}
	if !isValidMerkleBranch(h.Execution.HashTreeRoot(), h.ExecutionBranch,
		executionPayloadGindex, h.Beacon.BodyRoot) {
		return errors.New("invalid execution branch")
	}
	return nil
}

func (c *EthLightClient) verifyMisbehaviour(m *Misbehaviour) error {
	trusted, err := c.trustedState(m.TrustedSlot, m.ActiveSyncCommittee, m.ActiveIsNext)
	if err != nil {
		return err
	}
	if m.Update1.AttestedHeader.Beacon.Slot != m.Update2.AttestedHeader.Beacon.Slot {
		return errors.New("misbehaviour updates attest different slots")
	}
	if bytesEqual(m.Update1.AttestedHeader.Execution.StateRoot, m.Update2.AttestedHeader.Execution.StateRoot) {
		return errors.New("misbehaviour updates attest the same state root")
	}
	current, err := c.currentSlot()
	if err != nil {
		return err
	}
	if err := c.validateUpdate(trusted, m.ActiveSyncCommittee, m.ActiveIsNext, m.Update1, current); err != nil {
		return ufmt.Errorf("update 1: %v", err)
	}
	if err := c.validateUpdate(trusted, m.ActiveSyncCommittee, m.ActiveIsNext, m.Update2, current); err != nil {
		return ufmt.Errorf("update 2: %v", err)
	}
	return nil
}

// Implements lightclient.Interface. A header that would store a different
// state root at a slot the client already holds is misbehaviour too.
func (c *EthLightClient) CheckForMisbehaviour(clientMsg lightclient.ClientMessage) bool {
	switch msg := clientMsg.(type) {
	case *Misbehaviour:
		return true
	case *Header:
		u := msg.ConsensusUpdate
		existing, ok := c.GetConsensusState(heightAtSlot(u.FinalizedHeader.Beacon.Slot))
		return ok && !bytesEqual(existing.StateRoot, u.FinalizedHeader.Execution.StateRoot)
	}
	return false
}

// Implements lightclient.Interface.
func (c *EthLightClient) UpdateStateOnMisbehaviour(lightclient.ClientMessage) {
	cs := *c.ClientState
	cs.IsFrozen = true
	c.ClientState = &cs
}

// Implements lightclient.Interface: update_consensus_state.
func (c *EthLightClient) UpdateState(clientMsg lightclient.ClientMessage) []types.Height {
	h, ok := clientMsg.(*Header)
	if !ok {
		panic(ufmt.Sprintf("expected *ethereum.Header, got %T", clientMsg))
	}
	cs := c.ClientState
	trusted, ok := c.GetConsensusState(heightAtSlot(h.TrustedSlot))
	if !ok {
		panic("trusted consensus state disappeared")
	}
	u := h.ConsensusUpdate
	storePeriod := cs.periodAtSlot(trusted.Slot)
	finalizedSlot := u.FinalizedHeader.Beacon.Slot
	finalizedPeriod := cs.periodAtSlot(finalizedSlot)

	next := copyConsensusState(*trusted)
	var updateNext *SummarizedSyncCommittee
	if u.NextSyncCommittee != nil {
		s := u.NextSyncCommittee.summarize()
		updateNext = &s
	}
	if trusted.NextSyncCommittee != nil {
		if finalizedPeriod == storePeriod+1 {
			next.CurrentSyncCommittee = *trusted.NextSyncCommittee
			next.NextSyncCommittee = updateNext
		}
	} else {
		if finalizedPeriod != storePeriod {
			panic("store period must equal the finalized period")
		}
		next.NextSyncCommittee = updateNext
	}
	next.Slot = finalizedSlot
	next.StateRoot = u.FinalizedHeader.Execution.StateRoot
	next.Timestamp = u.FinalizedHeader.Execution.Timestamp
	c.setConsensusState(&next)

	if finalizedSlot > cs.LatestSlot {
		updated := *cs
		updated.LatestSlot = finalizedSlot
		updated.LatestExecutionBlockNumber = u.FinalizedHeader.Execution.BlockNumber
		c.ClientState = &updated
	}
	return []types.Height{heightAtSlot(finalizedSlot)}
}

// VerifyMembership implements lightclient.Interface. This client's proofs are
// not ICS23 proofs: relayers must pass a MembershipProof in the message's Ext
// field, which reaches VerifyMembershipProof.
func (c *EthLightClient) VerifyMembership(types.Height, []ics23.CommitmentProof, types.MerklePath, []byte) error {
	return errors.New("ethereum light client proofs must be passed as an extproof.Proof")
}

// VerifyNonMembership implements lightclient.Interface; see VerifyMembership.
func (c *EthLightClient) VerifyNonMembership(types.Height, []ics23.CommitmentProof, types.MerklePath) error {
	return errors.New("ethereum light client proofs must be passed as an extproof.Proof")
}

// VerifyMembershipProof implements extproof.Verifier: value must be the
// 32-byte value of the ICS26 commitment at path.
func (c *EthLightClient) VerifyMembershipProof(height types.Height, proof any, path types.MerklePath, value []byte) error {
	if len(value) != hashSize {
		return ufmt.Errorf("commitment value must be 32 bytes, got %d", len(value))
	}
	stored, err := c.provenCommitment(height, proof, path)
	if err != nil {
		return err
	}
	if !bytesEqual(stored, value) {
		return errors.New("stored commitment differs from the expected value")
	}
	return nil
}

// VerifyNonMembershipProof implements extproof.Verifier.
func (c *EthLightClient) VerifyNonMembershipProof(height types.Height, proof any, path types.MerklePath) error {
	stored, err := c.provenCommitment(height, proof, path)
	if err != nil {
		return err
	}
	if !bytesEqual(stored, make([]byte, hashSize)) {
		return errors.New("a commitment is stored at the path")
	}
	return nil
}

// provenCommitment returns the value of the router's commitments[keccak256(path)]
// at height, zero if unset, as established by proof.
func (c *EthLightClient) provenCommitment(height types.Height, proof any, path types.MerklePath) ([]byte, error) {
	var mp MembershipProof
	switch p := proof.(type) {
	case MembershipProof:
		mp = p
	case *MembershipProof:
		if p == nil {
			return nil, errors.New("nil membership proof")
		}
		mp = *p
	default:
		return nil, ufmt.Errorf("expected ethereum.MembershipProof, got %T", proof)
	}
	if height.RevisionNumber != 0 {
		return nil, ufmt.Errorf("revision number must be 0, got %d", height.RevisionNumber)
	}
	if c.ClientState.LatestSlot < height.RevisionHeight {
		return nil, ufmt.Errorf("proof slot %d is after the latest slot %d", height.RevisionHeight, c.ClientState.LatestSlot)
	}
	cons, ok := c.GetConsensusState(height)
	if !ok {
		return nil, ufmt.Errorf("no consensus state at slot %d", height.RevisionHeight)
	}
	if len(path.KeyPath) != 1 {
		return nil, ufmt.Errorf("path must have exactly one element, got %d", len(path.KeyPath))
	}
	storageRoot, err := accountStorageRoot(cons.StateRoot, c.ClientState.IBCContractAddress, mp.AccountProof)
	if err != nil {
		return nil, ufmt.Errorf("account proof: %v", err)
	}
	slot := commitmentStorageSlot(path.KeyPath[0], c.ClientState.IBCCommitmentSlot)
	v, err := storageValue(storageRoot, slot, mp.StorageProof)
	if err != nil {
		return nil, ufmt.Errorf("storage proof: %v", err)
	}
	return v, nil
}

// commitmentStorageSlot is the storage slot of commitments[keccak256(path)]
// in the router, whose commitments mapping is at mappingSlot.
func commitmentStorageSlot(path, mappingSlot []byte) []byte {
	return keccak(append(keccak(path), mappingSlot...))
}

// Implements lightclient.Interface. The client never expires on its own: a
// client that misses a whole sync committee period can no longer verify
// updates and must be recovered.
func (c *EthLightClient) Status() lightclient.Status {
	if c.ClientState.IsFrozen {
		return lightclient.Frozen
	}
	if _, ok := c.GetConsensusState(c.LatestHeight()); !ok {
		return lightclient.Expired
	}
	return lightclient.Active
}

// Implements lightclient.Interface.
func (c *EthLightClient) LatestHeight() types.Height {
	return heightAtSlot(c.ClientState.LatestSlot)
}

// Implements lightclient.Interface: the execution block time, in seconds.
func (c *EthLightClient) TimestampAtHeight(height types.Height) (uint64, error) {
	cons, ok := c.GetConsensusState(height)
	if !ok {
		return 0, ufmt.Errorf("no consensus state at height %s", height.String())
	}
	return cons.Timestamp, nil
}

// Implements lightclient.Interface. The substitute must track the same chain
// and router; its latest consensus state is copied and the subject unfrozen.
func (c *EthLightClient) RecoverClient(substitute lightclient.Interface) error {
	sub, ok := substitute.(*EthLightClient)
	if !ok {
		return ufmt.Errorf("substitute must be an ethereum client, got %T", substitute)
	}
	a, b := c.ClientState, sub.ClientState
	if a.ChainID != b.ChainID || !bytesEqual(a.GenesisValidatorsRoot, b.GenesisValidatorsRoot) ||
		a.ForkParameters != b.ForkParameters || a.SyncCommitteeSize != b.SyncCommitteeSize ||
		a.GenesisTime != b.GenesisTime || a.GenesisSlot != b.GenesisSlot ||
		a.SecondsPerSlot != b.SecondsPerSlot || a.SlotsPerEpoch != b.SlotsPerEpoch ||
		a.EpochsPerSyncCommitteePeriod != b.EpochsPerSyncCommitteePeriod ||
		!bytesEqual(a.IBCContractAddress, b.IBCContractAddress) ||
		!bytesEqual(a.IBCCommitmentSlot, b.IBCCommitmentSlot) {
		return errors.New("substitute client tracks a different chain or router")
	}
	if b.LatestSlot <= a.LatestSlot {
		return errors.New("substitute must be ahead of the subject")
	}
	cons, ok := sub.GetConsensusState(sub.LatestHeight())
	if !ok {
		return errors.New("substitute has no latest consensus state")
	}
	copied := copyConsensusState(*cons)
	c.setConsensusState(&copied)
	updated := *a
	updated.LatestSlot = b.LatestSlot
	updated.LatestExecutionBlockNumber = b.LatestExecutionBlockNumber
	updated.MinSyncCommitteeParticipants = b.MinSyncCommitteeParticipants
	updated.IsFrozen = false
	c.ClientState = &updated
	return nil
}

// Implements lightclient.Interface. Ethereum has no IBC upgrade path; replace
// the client with RecoverClient instead.
func (c *EthLightClient) VerifyUpgradeAndUpdateState(_, _, _, _ any) error {
	return errors.New("the ethereum light client does not support upgrades")
}

func (c *EthLightClient) setConsensusState(cons *ConsensusState) {
	c.ConsensusStateByHeight.Set(heightAtSlot(cons.Slot).StringNatSort(), cons)
}

// GetConsensusState returns the consensus state at height, if any.
func (c *EthLightClient) GetConsensusState(height types.Height) (*ConsensusState, bool) {
	v := c.ConsensusStateByHeight.Get(height.StringNatSort())
	if v == nil {
		return nil, false
	}
	return v.(*ConsensusState), true
}
