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
	"bytes"
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

	// verified is whether the client has applied a signed update, and
	// verifiedFrom and verifiedTo bound the slots whose forks those updates
	// were verified under (see keepsVerifiedForks). The initial consensus
	// state is trusted as given: a client that applied no update verified
	// nothing under its fork schedule.
	verified                 bool
	verifiedFrom, verifiedTo uint64
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
	cs.GenesisValidatorsRoot = cloneBytes(cs.GenesisValidatorsRoot)
	cs.IBCContractAddress = cloneBytes(cs.IBCContractAddress)
	cs.IBCCommitmentSlot = cloneBytes(cs.IBCCommitmentSlot)
	c.ClientState = &cs
	cons := copyConsensusState(in)
	c.setConsensusState(&cons)
	return nil
}

// cloneBytes copies b into an array allocated by the running realm. Every
// byte slice the client keeps goes through it: a slice taken from the caller
// stays owned by the caller's realm, which could change it after a verified
// update and so rewrite a trusted state root or committee.
func cloneBytes(b []byte) []byte {
	if b == nil {
		return nil
	}
	return append([]byte{}, b...)
}

func cloneSummary(in SummarizedSyncCommittee) SummarizedSyncCommittee {
	return SummarizedSyncCommittee{
		PubkeysHash:     cloneBytes(in.PubkeysHash),
		AggregatePubkey: cloneBytes(in.AggregatePubkey),
	}
}

// copyConsensusState returns a deep copy of in: no byte slice is shared.
func copyConsensusState(in ConsensusState) ConsensusState {
	out := ConsensusState{
		Slot:                 in.Slot,
		StateRoot:            cloneBytes(in.StateRoot),
		Timestamp:            in.Timestamp,
		CurrentSyncCommittee: cloneSummary(in.CurrentSyncCommittee),
	}
	if in.NextSyncCommittee != nil {
		next := cloneSummary(*in.NextSyncCommittee)
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
		return 0, errors.New("current time precedes the tracked chain's genesis, or its slot overflows")
	}
	return slot, nil
}

// trustedState returns the consensus state at slot.
func (c *EthLightClient) trustedState(slot uint64) (*ConsensusState, error) {
	cons, ok := c.GetConsensusState(heightAtSlot(slot))
	if !ok {
		return nil, ufmt.Errorf("no consensus state at trusted slot %d", slot)
	}
	return cons, nil
}

// verifyHeader implements verify_header.
func (c *EthLightClient) verifyHeader(h *Header) error {
	cs := c.ClientState
	// Also checked by core before it calls VerifyClientMessage; repeated here so
	// no caller of the client can skip the size checks.
	if err := h.ValidateBasic(); err != nil {
		return err
	}
	if err := c.checkLatestAnchor(h.TrustedSlot); err != nil {
		return err
	}
	trusted, err := c.trustedState(h.TrustedSlot)
	if err != nil {
		return err
	}
	current, err := c.currentSlot()
	if err != nil {
		return err
	}
	u := h.ConsensusUpdate
	// Only a 2/3 supermajority may move the client; checked first, as for
	// misbehaviour, so no signature is verified for an update that could not
	// apply.
	if !hasSupermajority(u) {
		return errors.New("not enough sync committee signatures")
	}
	if err := c.validateUpdate(trusted, u, current); err != nil {
		return err
	}
	if u.FinalizedHeader.Beacon.Slot <= trusted.Slot {
		// As in the sync protocol's apply_light_client_update, an update that
		// does not advance finality is still useful when it reveals the next
		// sync committee: without it a client bootstrapped late in a period
		// could never cross into the next one. Only when that committee is
		// final: isNextCommitteeOnly requires the finalized header in the
		// attested header's period, which validateUpdate, like the spec's
		// validate_light_client_update, does not.
		if !isNextCommitteeOnly(cs, trusted, u) {
			return ufmt.Errorf("finalized slot %d is not after trusted slot %d", u.FinalizedHeader.Beacon.Slot, trusted.Slot)
		}
		return nil
	}
	// An update may cross into the next period without the committee after
	// it, as a finality update does at every rotation: as in the sync
	// protocol's apply_light_client_update, the new state then does not know
	// its next committee until a later update reveals it.
	return c.verifyFinalizedExecution(u)
}

// validateUpdate implements validate_light_client_update.
func (c *EthLightClient) validateUpdate(trusted *ConsensusState, u LightClientUpdate, currentSlot uint64) error {
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
	// The trusted state keeps the next committee's summary, so it answers
	// whether the next committee is known, as the spec's store does. The
	// relayer's Header.ActiveIsNext is not consulted.
	nextKnown := trusted.NextSyncCommittee != nil
	switch {
	case signaturePeriod == storedPeriod:
	case signaturePeriod == storedPeriod+1 && !nextKnown:
		return ufmt.Errorf("update signed in period %d, after the stored period, but the next sync committee is not known", signaturePeriod)
	case signaturePeriod != storedPeriod+1:
		return ufmt.Errorf("signature period %d is not the stored period %d or the next", signaturePeriod, storedPeriod)
	}

	attestedPeriod := cs.periodAtSlot(attestedSlot)
	isNextCommitteeUpdate := u.NextSyncCommittee != nil
	// The spec's update_has_next_sync_committee, which unlike
	// isNextCommitteeOnly puts no condition on the finalized header's period.
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
		cs.finalizedRootGindex(attestedSlot), u.AttestedHeader.Beacon.StateRoot) {
		return errors.New("invalid finality branch")
	}

	if isNextCommitteeUpdate {
		if attestedPeriod == storedPeriod && nextKnown && !u.NextSyncCommittee.equal(*trusted.NextSyncCommittee) {
			return errors.New("next sync committee does not match the trusted one")
		}
		if !isValidMerkleBranch(u.NextSyncCommittee.committeeRoot(), u.NextSyncCommitteeBranch,
			cs.nextSyncCommitteeGindex(attestedSlot), u.AttestedHeader.Beacon.StateRoot) {
			return errors.New("invalid next sync committee branch")
		}
	}

	// The signing committee follows from the signature period: the current
	// one within the stored period, the next one, known as checked above,
	// across it.
	active := trusted.CurrentSyncCommittee
	if signaturePeriod != storedPeriod {
		active = *trusted.NextSyncCommittee
	}
	excluded, err := c.nonSignerKeys(active, u)
	if err != nil {
		return err
	}

	forkVersionSlot := u.SignatureSlot
	if forkVersionSlot > 0 {
		forkVersionSlot--
	}
	forkVersion := cs.ForkParameters.forkVersion(cs.epochAtSlot(forkVersionSlot))
	domain := computeDomain(domainSyncCommittee, forkVersion, cs.GenesisValidatorsRoot)
	signingRoot := computeSigningRoot(u.AttestedHeader.Beacon.HashTreeRoot(), domain)
	// The committee commits to its aggregate key next to its keys, so the
	// signers' aggregate is it minus the non-signers': a few keys to decode
	// instead of hundreds.
	if !bls12381.FastAggregateVerifyExcluding(active.AggregatePubkey, excluded,
		signingRoot, u.SyncAggregate.SyncCommitteeSignature) {
		return errors.New("invalid sync committee signature")
	}
	return nil
}

// nonSignerKeys checks that u.NonSigners are exactly the members of the
// committee summarized by active whose participation bit is unset, each proven
// at its index against the committee's pubkeys root, and returns their keys
// concatenated.
func (c *EthLightClient) nonSignerKeys(active SummarizedSyncCommittee, u LightClientUpdate) ([]byte, error) {
	size := c.ClientState.SyncCommitteeSize
	bits := u.SyncAggregate.SyncCommitteeBits
	if uint64(len(bits))*8 != size {
		return nil, ufmt.Errorf("sync committee bits cover %d members, committee has %d", len(bits)*8, size)
	}
	var excluded []byte
	next := 0
	for i := uint64(0); i < size; i++ {
		if bits[i/8]&(1<<(i%8)) != 0 {
			continue
		}
		if next == len(u.NonSigners) {
			return nil, ufmt.Errorf("non-signer %d is missing", i)
		}
		ns := u.NonSigners[next]
		next++
		if !isValidMerkleBranch(pubkeyLeaf(ns.Pubkey), ns.Branch, size+i, active.PubkeysHash) {
			return nil, ufmt.Errorf("invalid branch for non-signer %d", i)
		}
		excluded = append(excluded, ns.Pubkey...)
	}
	if next != len(u.NonSigners) {
		return nil, errors.New("more non-signers than unset participation bits")
	}
	return excluded, nil
}

// validateLightClientHeader implements is_valid_light_client_header for
// Electra and later: the execution payload header, or from Gloas on the
// execution block hash, is in the beacon block body.
//
// An Electra or Fulu header may come in either form: with its execution
// payload header (gindex 25), or, as Gloas' upgrade_lc_header_to_gloas
// converts it and the beacon API serves it once Gloas is live, with only the
// payload's block hash (gindex 812, EXECUTION_BLOCK_HASH_GINDEX_DENEB). A
// Gloas header has only the hash form. A header carrying both, or neither, is
// refused.
func (c *EthLightClient) validateLightClientHeader(h LightClientHeader) error {
	if err := c.ClientState.verifySupportedFork(h.Beacon.Slot); err != nil {
		return err
	}
	// SSZ hashes fixed-size fields as chunks laid side by side: a field of the
	// wrong length could shift bytes into its neighbour and keep the root, so
	// every fixed size is checked before hashing.
	if err := h.Beacon.validateSizes(); err != nil {
		return err
	}
	if err := validateBranch(h.ExecutionBranch); err != nil {
		return ufmt.Errorf("execution branch: %v", err)
	}
	gloas := c.ClientState.isGloas(h.Beacon.Slot)
	hashForm := h.hashForm()
	if hashForm && !h.Execution.isEmpty() {
		return errors.New("header carries both an execution payload header and an execution block hash")
	}
	leaf, gindex := []byte(nil), uint64(executionPayloadGindex)
	if gloas || hashForm {
		if len(h.ExecutionBlockHash) != hashSize {
			return errors.New("execution block hash must be 32 bytes")
		}
		leaf, gindex = h.ExecutionBlockHash, executionBlockHashGindexDeneb
		if gloas {
			gindex = executionBlockHashGindexGloas
		}
	} else {
		if err := h.Execution.validateSizes(); err != nil {
			return err
		}
		leaf = h.Execution.HashTreeRoot()
	}
	if !isValidMerkleBranch(leaf, h.ExecutionBranch, gindex, h.Beacon.BodyRoot) {
		return errors.New("invalid execution branch")
	}
	return nil
}

// executionData is what the client keeps of an execution block.
type executionData struct {
	stateRoot   []byte
	timestamp   uint64
	blockNumber uint64
}

// verifyFinalizedExecution checks, for a finalized header in the hash form
// (every Gloas header, and an Electra or Fulu one converted to it), that the
// update's RLP execution header is the one whose hash it commits to. A header
// in the payload form is proven by its execution branch.
func (c *EthLightClient) verifyFinalizedExecution(u LightClientUpdate) error {
	h := u.FinalizedHeader
	if !h.hashForm() {
		return nil
	}
	if !bytes.Equal(keccak(u.FinalizedExecutionHeader), h.ExecutionBlockHash) {
		return errors.New("finalized execution header does not match the execution block hash")
	}
	return nil
}

// finalizedExecution returns the execution data of the update's finalized
// header: its execution payload header in the payload form, the decoded RLP
// execution block header in the hash form. Before Gloas that is the block's
// own payload; from Gloas on, the hash is the bid's parent_block_hash, so the
// data is the parent execution block's. It does not check that header's hash: call it
// only on an update whose header verifyFinalizedExecution accepted. Once the
// hash matches, the bytes are the header the signed beacon chain committed
// to, so they are decoded once, where the data is used.
func (c *EthLightClient) finalizedExecution(u LightClientUpdate) (executionData, error) {
	h := u.FinalizedHeader
	if !h.hashForm() {
		return executionData{h.Execution.StateRoot, h.Execution.Timestamp, h.Execution.BlockNumber}, nil
	}
	return decodeExecutionHeader(u.FinalizedExecutionHeader)
}

// verifyMisbehaviour accepts two valid updates that finalize different beacon
// headers at the same slot: conflicting finality, which an honest chain never
// produces. Different attested heads alone are not misbehaviour, since sync
// committees sign their fork-choice head and an ordinary reorg yields two.
// Like an update, the evidence must build on the latest trusted state of a
// client that has not expired, so a past committee cannot freeze it.
func (c *EthLightClient) verifyMisbehaviour(m *Misbehaviour) error {
	if err := m.ValidateBasic(); err != nil {
		return err
	}
	if err := c.checkLatestAnchor(m.TrustedSlot); err != nil {
		return err
	}
	trusted, err := c.trustedState(m.TrustedSlot)
	if err != nil {
		return err
	}
	if m.Update1.FinalizedHeader.Beacon.Slot != m.Update2.FinalizedHeader.Beacon.Slot {
		return errors.New("misbehaviour updates finalize different slots")
	}
	if bytes.Equal(m.Update1.FinalizedHeader.Beacon.HashTreeRoot(), m.Update2.FinalizedHeader.Beacon.HashTreeRoot()) {
		return errors.New("misbehaviour updates finalize the same beacon header")
	}
	// Evidence needs the same 2/3 supermajority as an update moving the client,
	// not only the configured minimum participation.
	if !hasSupermajority(m.Update1) || !hasSupermajority(m.Update2) {
		return errors.New("not enough sync committee signatures")
	}
	current, err := c.currentSlot()
	if err != nil {
		return err
	}
	if err := c.validateUpdate(trusted, m.Update1, current); err != nil {
		return ufmt.Errorf("update 1: %v", err)
	}
	if err := c.validateUpdate(trusted, m.Update2, current); err != nil {
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
		if !ok {
			return false
		}
		// A stored slot means the update does not advance finality, and
		// verifyHeader then returns before checking the execution header's
		// hash: check it here, or any bytes decoding to another state root
		// would freeze the client.
		if c.verifyFinalizedExecution(u) != nil {
			return false
		}
		exec, err := c.finalizedExecution(u)
		return err == nil && !bytes.Equal(existing.StateRoot, exec.stateRoot)
	}
	return false
}

// Implements lightclient.Interface.
func (c *EthLightClient) UpdateStateOnMisbehaviour(lightclient.ClientMessage) {
	cs := *c.ClientState
	cs.IsFrozen = true
	c.ClientState = &cs
}

// isNextCommitteeOnly reports whether u only reveals the next sync committee
// of the trusted state's period, which the trusted state does not know yet.
// As in the sync protocol's update_has_finalized_next_sync_committee, the
// update's finalized header must be in the attested header's period: a
// period's next committee is set at its first slot, so it is final only once
// a header of that period is.
func isNextCommitteeOnly(cs *ClientState, trusted *ConsensusState, u LightClientUpdate) bool {
	attestedPeriod := cs.periodAtSlot(u.AttestedHeader.Beacon.Slot)
	return trusted.NextSyncCommittee == nil && u.NextSyncCommittee != nil &&
		attestedPeriod == cs.periodAtSlot(trusted.Slot) &&
		cs.periodAtSlot(u.FinalizedHeader.Beacon.Slot) == attestedPeriod
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
	if u.FinalizedHeader.Beacon.Slot <= trusted.Slot {
		// A next-committee-only update (see verifyHeader): record the
		// committee in the trusted state and change nothing else.
		next := copyConsensusState(*trusted)
		s := cloneSummary(*u.NextSyncCommittee)
		next.NextSyncCommittee = &s
		c.setConsensusState(&next)
		c.recordVerified(u)
		return []types.Height{heightAtSlot(trusted.Slot)}
	}
	storePeriod := cs.periodAtSlot(trusted.Slot)
	finalizedSlot := u.FinalizedHeader.Beacon.Slot
	finalizedPeriod := cs.periodAtSlot(finalizedSlot)

	next := copyConsensusState(*trusted)
	var updateNext *SummarizedSyncCommittee
	if u.NextSyncCommittee != nil {
		s := cloneSummary(*u.NextSyncCommittee)
		updateNext = &s
	}
	if trusted.NextSyncCommittee != nil {
		if finalizedPeriod == storePeriod+1 {
			// next is a deep copy of trusted already: taking its committee
			// shares no slice with the stored state.
			next.CurrentSyncCommittee = *next.NextSyncCommittee
			next.NextSyncCommittee = updateNext
		}
	} else {
		if finalizedPeriod != storePeriod {
			panic("store period must equal the finalized period")
		}
		next.NextSyncCommittee = updateNext
	}
	exec, err := c.finalizedExecution(u)
	if err != nil {
		panic(err) // checked by VerifyClientMessage
	}
	next.Slot = finalizedSlot
	next.StateRoot = cloneBytes(exec.stateRoot)
	next.Timestamp = exec.timestamp
	c.setConsensusState(&next)
	c.recordVerified(u)

	if finalizedSlot > cs.LatestSlot {
		updated := *cs
		updated.LatestSlot = finalizedSlot
		updated.LatestExecutionBlockNumber = exec.blockNumber
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
	if !bytes.Equal(stored, value) {
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
	if !bytes.Equal(stored, make([]byte, hashSize)) {
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

// TrustingPeriods is how many sync committee periods (about 27 hours each on
// mainnet) the latest trusted state stays usable. Past that the client
// expires: its committees are too old to trust, so only a governed recovery
// can bring it back.
const TrustingPeriods = 8

// hasSupermajority reports whether at least 2/3 of the sync committee signed u.
func hasSupermajority(u LightClientUpdate) bool {
	return u.SyncAggregate.participants()*3 >= u.SyncAggregate.size()*2
}

// expired reports whether more than TrustingPeriods sync committee periods'
// worth of slots have passed since the latest trusted slot. It counts slots,
// not period numbers, so the window is the same wherever in a period the
// latest trusted slot falls.
func (c *EthLightClient) expired() bool {
	current, err := c.currentSlot()
	if err != nil {
		return false
	}
	cs := c.ClientState
	// Elapsed slots by subtraction: LatestSlot plus the window could wrap.
	return current > cs.LatestSlot && current-cs.LatestSlot > cs.trustWindow()
}

// checkLatestAnchor requires a client message to build on the latest trusted
// state, as the spec's single store does, of a client that has not expired.
// Anchoring at an older stored state would let a past sync committee, long
// rotated out and never slashable, insert state roots below the latest slot
// that packet proofs would accept, or freeze the client.
func (c *EthLightClient) checkLatestAnchor(trustedSlot uint64) error {
	cs := c.ClientState
	if trustedSlot != cs.LatestSlot {
		return ufmt.Errorf("updates must build on the latest trusted slot %d, not %d", cs.LatestSlot, trustedSlot)
	}
	if c.expired() {
		return ufmt.Errorf("client expired: its latest trusted slot %d is more than %d sync committee periods old", cs.LatestSlot, TrustingPeriods)
	}
	return nil
}

// Implements lightclient.Interface. The client expires TrustingPeriods sync
// committee periods after its latest trusted slot and must then be recovered.
func (c *EthLightClient) Status() lightclient.Status {
	if c.ClientState.IsFrozen {
		return lightclient.Frozen
	}
	if _, ok := c.GetConsensusState(c.LatestHeight()); !ok {
		return lightclient.Expired
	}
	if c.expired() {
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
// It may schedule forks differently wherever the subject verified nothing
// (see keepsVerifiedForks), and the subject takes its fork schedule.
func (c *EthLightClient) RecoverClient(substitute lightclient.Interface) error {
	sub, ok := substitute.(*EthLightClient)
	if !ok {
		return ufmt.Errorf("substitute must be an ethereum client, got %T", substitute)
	}
	a, b := c.ClientState, sub.ClientState
	if !sameChainAndRouter(a, b) {
		return errors.New("substitute client tracks a different chain or router")
	}
	if err := b.ForkParameters.validate(); err != nil {
		return ufmt.Errorf("substitute fork schedule: %v", err)
	}
	if !c.keepsVerifiedForks(b.ForkParameters) {
		return errors.New("substitute changes a fork the subject verified updates under")
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
	updated.ForkParameters = b.ForkParameters
	updated.IsFrozen = false
	c.ClientState = &updated
	// The subject keeps its own consensus states and now holds one the
	// substitute verified: both ranges are verified under the new schedule.
	c.mergeVerified(sub)
	return nil
}

// sameChainAndRouter reports whether a and b track the same chain, with the
// same slot clock and committee size, and the same router: every client state
// field but the fork schedule, the latest slot and block number, the
// minimum participation and the frozen flag.
func sameChainAndRouter(a, b *ClientState) bool {
	return a.ChainID == b.ChainID && bytes.Equal(a.GenesisValidatorsRoot, b.GenesisValidatorsRoot) &&
		a.SyncCommitteeSize == b.SyncCommitteeSize &&
		a.GenesisTime == b.GenesisTime && a.GenesisSlot == b.GenesisSlot &&
		a.SecondsPerSlot == b.SecondsPerSlot && a.SlotsPerEpoch == b.SlotsPerEpoch &&
		a.EpochsPerSyncCommitteePeriod == b.EpochsPerSyncCommitteePeriod &&
		bytes.Equal(a.IBCContractAddress, b.IBCContractAddress) &&
		bytes.Equal(a.IBCCommitmentSlot, b.IBCCommitmentSlot)
}

// recordVerified extends the range of slots whose forks the client verified
// a signed update under with u's: its finalized slot (the lowest it reads)
// to its signature slot minus one (the slot its signing domain comes from).
func (c *EthLightClient) recordVerified(u LightClientUpdate) {
	c.extendVerified(u.FinalizedHeader.Beacon.Slot, u.SignatureSlot-1)
}

func (c *EthLightClient) extendVerified(from, to uint64) {
	if !c.verified || from < c.verifiedFrom {
		c.verifiedFrom = from
	}
	if !c.verified || to > c.verifiedTo {
		c.verifiedTo = to
	}
	c.verified = true
}

func (c *EthLightClient) mergeVerified(o *EthLightClient) {
	if o.verified {
		c.extendVerified(o.verifiedFrom, o.verifiedTo)
	}
}

// keepsVerifiedForks reports whether fp schedules every fork c verified a
// signed update under as c's own schedule does: the same fork version, the
// same Merkle layout (Gloas or not) and the same supported range (Electra or
// later) at every epoch from c's lowest verified slot to its highest. Forks
// outside that range may differ, so governance can schedule a fork the chain
// announced after the client was created, move one it postponed, or repair a
// schedule the client never verified anything under.
//
// The range, not the latest slot, is what counts. The client's initial
// consensus state is trusted as given, not verified: a client created with a
// wrong schedule for a fork already active at its creation accepts no
// update, and since it verified nothing it may take any valid schedule. And
// a fork active at the latest slot but superseded before the first verified
// slot, whose version no update read, may differ too. Within the range the
// stored consensus states were verified under c's schedule: a substitute,
// successor or migration that changed it there would say they were verified
// under the wrong one.
//
// ForkParameters has no slot after Gloas, and a fork that moves the
// light-client containers (new generalized indices, as Gloas did) needs new
// verification code too: such a fork still needs a new client package.
func (c *EthLightClient) keepsVerifiedForks(fp ForkParameters) bool {
	if !c.verified {
		return true
	}
	cs := c.ClientState
	return sameForksOver(cs.ForkParameters, fp, cs.epochAtSlot(c.verifiedFrom), cs.epochAtSlot(c.verifiedTo))
}

// sameForksOver reports whether a and b give every epoch from from to to the
// same fork version, layout and support. Each is constant between fork
// epochs, so comparing at from and at every fork epoch of either schedule in
// (from, to] covers the range.
func sameForksOver(a, b ForkParameters, from, to uint64) bool {
	same := func(e uint64) bool {
		return a.forkVersion(e) == b.forkVersion(e) &&
			(e >= a.Gloas.Epoch) == (e >= b.Gloas.Epoch) &&
			(e >= a.Electra.Epoch) == (e >= b.Electra.Epoch)
	}
	if !same(from) {
		return false
	}
	for _, p := range []ForkParameters{a, b} {
		for _, f := range p.forks() {
			if f.Epoch > from && f.Epoch <= to && !same(f.Epoch) {
				return false
			}
		}
	}
	return true
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
