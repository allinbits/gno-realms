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
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"

	"crypto/bls12381"

	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/ics23/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

// EthLightClient is the light client. Consensus states are keyed by the
// height {0, finalized slot}.
type EthLightClient struct {
	ClientState            *ClientState
	ConsensusStateByHeight *bptree.BPTree // height:*ConsensusState
	// TrustedFromSlot is the slot of the consensus state a recovery copied:
	// the states below it were trusted by the verifier the recovery replaced,
	// so no proof, timestamp or update is ever read from them again.
	TrustedFromSlot uint64
	// history is the verifiers replacements retired before this one
	// (NewFrom), read only, keyed by the latest slot each had when it was
	// retired (zero-padded): a persistent tree, shared with the verifiers it
	// came from and never written through, so a height none of the newer
	// stores holds is found by one ordered lookup, in O(log replacements),
	// however many replacements there were (no chain of delegations).
	history *avl.Node
	// overrides is the consensus states a retired verifier rewrote at slots
	// an earlier store's interval already covers (a next-committee-only
	// update of the head it inherited), keyed by historyKey(slot), consulted
	// before history: a persistent tree, copy-on-write like history, holding
	// at most the few heads each replacement carried.
	overrides *avl.Node
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

// Version names this verifier package and version, which a governed verifier
// replacement converts from (core.RegisterVerifier).
const Version = "ethereum/v0"

// VerifierVersion is Version: the core reads it to tell which verifier a
// client holds.
func (c *EthLightClient) VerifierVersion() string { return Version }

// Ethereum is the v0 verifier itself: a later verifier version that wraps it
// keeps exposing its state, so renders and recoveries read it whatever wraps
// it.
func (c *EthLightClient) Ethereum() *EthLightClient { return c }

// RouteIdentity is the history this verifier authenticates (ADR pr6375
// §7.12, "Route identity is preserved"): the Ethereum chain (its chain id and
// genesis validators root), the ICS26 router and its commitments slot. router
// is the router's address in lower case with "0x". Every field is fixed at
// creation: no update, recovery or verifier replacement changes it.
func (c *EthLightClient) RouteIdentity() (identity, router string) {
	cs := c.ClientState
	router = "0x" + hex.EncodeToString(cs.IBCContractAddress)
	identity = "chain " + strconv.FormatUint(cs.ChainID, 10) +
		", genesis validators root 0x" + hex.EncodeToString(cs.GenesisValidatorsRoot) +
		", router " + router +
		", commitment slot 0x" + hex.EncodeToString(cs.IBCCommitmentSlot)
	return identity, router
}

// ethState is a verifier exposing ethereum/v0 state: this one, or a later
// version wrapping it.
type ethState interface {
	Ethereum() *EthLightClient
}

// Retire is a read-only view of c, the verifier a replacement is about to
// retire: what a conversion is handed, so it reads c and can never write to
// it. The view serves the consensus states c trusts at or below its latest
// slot.
func Retire(c *EthLightClient) *Retired {
	return &Retired{c: c, upTo: c.ClientState.LatestSlot}
}

// NewFrom is a verifier that continues the retired one r views, for a
// verifier replacement (ADR pr6375 R16), copying no consensus-state history
// (O(log previous stores), the persistent trees' insertions copying their
// search paths): a deep copy of its client state, and r, from which it serves every
// consensus state at or below the retired verifier's latest slot, so every
// height it trusted stays provable. Its own consensus states, those it stores
// from now on, are kept apart (an overlay), and nothing writes to the retired
// verifier: r is the only reference, and it only reads.
func NewFrom(r *Retired) *EthLightClient {
	cs := r.ClientState()
	// Each store in the history owns the interval of slots above the
	// previous one's key and up to its own: non-overlapping. The retired
	// verifier's own store joins it only when it holds a slot above every
	// key (its finality advanced since it was created). Any state it holds
	// at or below the highest key (at most the head it inherited, rewritten
	// by a next-committee-only update) is an override of an earlier store's
	// interval: it is copied into the overrides, consulted first, so it is
	// never lost to that interval whether or not finality advanced after it.
	// Both trees are persistent: the retired verifier's own are not changed.
	hist, ovr := r.c.history, r.c.overrides
	if r.c.ConsensusStateByHeight.Size() > 0 {
		var top uint64
		hasTop := false
		hist.ReverseIterate("", "", func(n *avl.Node) bool {
			top, _ = strconv.ParseUint(n.Key(), 10, 64)
			hasTop = true
			return true
		})
		if hasTop {
			// Bounded: a verifier's own store holds no slot below the head
			// it was created with, so this visits at most that head.
			r.c.ConsensusStateByHeight.Iterate("", heightAtSlot(top+1).StringNatSort(), func(_ string, v any) bool {
				copied := copyConsensusState(*v.(*ConsensusState))
				ovr, _ = ovr.Set(historyKey(copied.Slot), &copied)
				return false
			})
		}
		if !hasTop || r.upTo > top {
			hist, _ = hist.Set(historyKey(r.upTo), r.c)
		}
	}
	return &EthLightClient{
		ClientState:            &cs,
		ConsensusStateByHeight: bptree.NewBPTree32(),
		TrustedFromSlot:        r.c.TrustedFromSlot,
		history:                hist,
		overrides:              ovr,
	}
}

// historyKey orders the retired verifiers by the latest slot they had.
func historyKey(slot uint64) string {
	s := strconv.FormatUint(slot, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

// fromHistory is the consensus state at height a retired verifier stores
// itself: the first one retired at a latest slot at or above it holds it,
// if any does (their own stores cover disjoint ranges of slots).
func (c *EthLightClient) fromHistory(height types.Height) (*ConsensusState, bool) {
	if _, v, ok := c.overrides.Get(historyKey(height.RevisionHeight)); ok {
		return v.(*ConsensusState), true
	}
	var owner *EthLightClient
	c.history.Iterate(historyKey(height.RevisionHeight), "", func(n *avl.Node) bool {
		owner = n.Value().(*EthLightClient)
		return true
	})
	if owner == nil {
		return nil, false
	}
	v := owner.ConsensusStateByHeight.Get(height.StringNatSort())
	if v == nil {
		return nil, false
	}
	return v.(*ConsensusState), true
}

// HistoryDepth is how many retired verifiers' stores this one reads through
// its history: each lookup is one ordered search of them.
func (c *EthLightClient) HistoryDepth() int { return c.history.Size() }

// Retired is a read-only view of a verifier a replacement retires: the
// consensus states it trusted, at or below upTo, and nothing to write with.
type Retired struct {
	c    *EthLightClient
	upTo uint64
}

// ClientState is a deep copy of the retired verifier's client state.
func (r *Retired) ClientState() ClientState {
	cs := *r.c.ClientState
	cs.GenesisValidatorsRoot = cloneBytes(cs.GenesisValidatorsRoot)
	cs.IBCContractAddress = cloneBytes(cs.IBCContractAddress)
	cs.IBCCommitmentSlot = cloneBytes(cs.IBCCommitmentSlot)
	return cs
}

// LatestHeight is the retired verifier's latest height.
func (r *Retired) LatestHeight() types.Height { return r.c.LatestHeight() }

// ConsensusState is a copy of the retired verifier's consensus state at
// height, if it trusted one there.
func (r *Retired) ConsensusState(height types.Height) (ConsensusState, bool) {
	cons, ok := r.consensusState(height)
	if !ok {
		return ConsensusState{}, false
	}
	return copyConsensusState(*cons), true
}

// consensusState is the retired verifier's consensus state at height, if it
// trusted one there.
func (r *Retired) consensusState(height types.Height) (*ConsensusState, bool) {
	if r == nil || height.RevisionHeight > r.upTo {
		return nil, false
	}
	return r.c.GetConsensusState(height)
}

// Implements lightclient.Interface. It runs once, on a client not yet
// initialized: a stored client's trusted state is never replaced through it.
func (c *EthLightClient) Initialize(clientState lightclient.ClientState, consensusState lightclient.ConsensusState) error {
	if c.ClientState != nil {
		return errors.New("ethereum client initialized already")
	}
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
	cs := c.ClientState
	elapsed, ok := cs.elapsedSlots(now())
	if !ok {
		return false // before genesis no window has started
	}
	// The latest slot's age, computed from slots since genesis so that
	// nothing wraps: an absolute current slot can pass 2^64 (slotAtTimestamp
	// then reports none), and LatestSlot plus the window can too.
	since := uint64(0)
	if cs.LatestSlot > cs.GenesisSlot {
		since = cs.LatestSlot - cs.GenesisSlot
	}
	return elapsed > since && elapsed-since > cs.trustWindow()
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
// and router (sameChainAndRouter), be a valid client, schedule included, and
// be ahead; its latest consensus state is copied, the subject unfrozen, and
// the subject adopts its fork schedule, whatever the subject's was.
//
// No fork comparison binds the substitute to the subject's schedule. Once a
// client exists, its schedule changes only on governed paths (this recovery,
// and on later core implementations a fork migration or a verifier
// conversion), and governance already has full power over a client through
// recovery from a substitute it created from a trusted bootstrap, so a
// comparison adds no safety against governance. A new client's schedule, like
// the rest of its initial state, is trusted from its creator (a whitelisted
// relayer, or anyone while the whitelist is empty), as any IBC client's
// creation is. A wrong schedule cannot make a relayed update verify false
// data: the update still needs a 2/3 sync committee signature over the chain's
// real domain and Merkle proofs into signed roots, and under the wrong layout
// each generalized index of the other fork lands on a value no relayer
// chooses (ADR 0003). A governed recovery, unlike a relayed update, adopts its
// substitute's state as trusted. At worst a wrong schedule stops the client
// from verifying, which another governed action repairs. Each comparison rule
// tried made some stalled or wrongly configured client unrepairable, since
// what the client "verified under" is partly untrusted input (the signature
// slot) and partly the wrong schedule being repaired.
//
// ForkParameters has no slot after Gloas, and a fork that moves the
// light-client containers (new generalized indices, as Gloas did) needs new
// verification code too: such a fork still needs a new client package.
func (c *EthLightClient) RecoverClient(substitute lightclient.Interface) error {
	if err := c.CheckRecovery(substitute); err != nil {
		return err
	}
	sub := substitute.(ethState).Ethereum()
	a, b := c.ClientState, sub.ClientState
	cons, _ := sub.GetConsensusState(sub.LatestHeight())
	copied := copyConsensusState(*cons)
	c.setConsensusState(&copied)
	updated := *a
	updated.LatestSlot = b.LatestSlot
	updated.LatestExecutionBlockNumber = b.LatestExecutionBlockNumber
	updated.MinSyncCommitteeParticipants = b.MinSyncCommitteeParticipants
	updated.ForkParameters = b.ForkParameters
	updated.IsFrozen = false
	c.ClientState = &updated
	c.TrustedFromSlot = copied.Slot
	return nil
}

// CheckRecovery is why RecoverClient would refuse substitute, or nil; it
// changes nothing, so a governed recovery is refused deterministically
// before it runs.
func (c *EthLightClient) CheckRecovery(substitute lightclient.Interface) error {
	// The v0 verifier, or a later version wrapping it.
	s, ok := substitute.(ethState)
	if !ok {
		return ufmt.Errorf("substitute must be an ethereum client, got %T", substitute)
	}
	sub := s.Ethereum()
	a, b := c.ClientState, sub.ClientState
	if !sameChainAndRouter(a, b) {
		return errors.New("substitute client tracks a different chain or router")
	}
	if err := b.ValidateBasic(); err != nil {
		return ufmt.Errorf("substitute client state: %v", err)
	}
	if b.LatestSlot <= a.LatestSlot {
		return errors.New("substitute must be ahead of the subject")
	}
	if _, ok := sub.GetConsensusState(sub.LatestHeight()); !ok {
		return errors.New("substitute has no latest consensus state")
	}
	return nil
}

// sameChainAndRouter reports whether a and b track the same chain, with the
// same slot clock, committee size and genesis fork, and the same router:
// every client state field but the fork schedule (its genesis fork version
// and slot excepted), the latest slot and block number, the minimum
// participation and the frozen flag.
func sameChainAndRouter(a, b *ClientState) bool {
	return a.ChainID == b.ChainID && bytes.Equal(a.GenesisValidatorsRoot, b.GenesisValidatorsRoot) &&
		a.ForkParameters.GenesisForkVersion == b.ForkParameters.GenesisForkVersion &&
		a.ForkParameters.GenesisSlot == b.ForkParameters.GenesisSlot &&
		a.SyncCommitteeSize == b.SyncCommitteeSize &&
		a.GenesisTime == b.GenesisTime && a.GenesisSlot == b.GenesisSlot &&
		a.SecondsPerSlot == b.SecondsPerSlot && a.SlotsPerEpoch == b.SlotsPerEpoch &&
		a.EpochsPerSyncCommitteePeriod == b.EpochsPerSyncCommitteePeriod &&
		bytes.Equal(a.IBCContractAddress, b.IBCContractAddress) &&
		bytes.Equal(a.IBCCommitmentSlot, b.IBCCommitmentSlot)
}

// Implements lightclient.Interface. Ethereum has no IBC upgrade path; replace
// the client with RecoverClient instead.
func (c *EthLightClient) VerifyUpgradeAndUpdateState(_, _, _, _ any) error {
	return errors.New("the ethereum light client does not support upgrades")
}

func (c *EthLightClient) setConsensusState(cons *ConsensusState) {
	c.ConsensusStateByHeight.Set(heightAtSlot(cons.Slot).StringNatSort(), cons)
}

// GetConsensusState returns the consensus state at height, if any and still
// trusted: one below TrustedFromSlot, from before a recovery, is not. An
// Ethereum height is revision 0 and a slot: any other revision holds none,
// whatever store (the client's own, the overrides, the history) would be
// read for its slot.
func (c *EthLightClient) GetConsensusState(height types.Height) (*ConsensusState, bool) {
	if height.RevisionNumber != 0 || height.RevisionHeight < c.TrustedFromSlot {
		return nil, false
	}
	v := c.ConsensusStateByHeight.Get(height.StringNatSort())
	if v == nil {
		// A height the retired verifier trusted before a replacement: a
		// copy, so no pointer into the retired verifier ever escapes, to a
		// later conversion least of all.
		cons, ok := c.fromHistory(height)
		if !ok {
			return nil, false
		}
		copied := copyConsensusState(*cons)
		return &copied, true
	}
	return v.(*ConsensusState), true
}
