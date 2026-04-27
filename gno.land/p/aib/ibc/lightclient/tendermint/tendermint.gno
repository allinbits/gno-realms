package tendermint

import (
	"bytes"
	"errors"
	"time"

	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type TMLightClient struct {
	ClientState            *ClientState
	ConsensusStateByHeight *avl.Tree // height:*ConsensusState
}

func NewTMLightClient() *TMLightClient {
	return &TMLightClient{
		ConsensusStateByHeight: avl.NewTree(),
	}
}

var _ lightclient.Interface = (*TMLightClient)(nil)

// Implements lightclient.Interface
func (tm *TMLightClient) Initialize(clientState lightclient.ClientState, consensusState lightclient.ConsensusState) error {
	cs := clientState.(ClientState)
	tm.ClientState = &cs
	consState := consensusState.(ConsensusState)
	consState.processedTime = time.Now()
	consState.processedHeight = types.GetSelfHeight()
	tm.SetConsensusState(cs.LatestHeight, &consState)
	return nil
}

// Implements lightclient.Interface
func (tm *TMLightClient) VerifyClientMessage(clientMsg lightclient.ClientMessage) error {
	switch msg := clientMsg.(type) {
	case *MsgHeader:
		return tm.verifyHeader(msg)
	case *Misbehaviour:
		return tm.verifyMisbehavior(msg)
	default:
		return errors.New("unknown client message type")
	}
}

// Implements lightclient.Interface
func (tm *TMLightClient) CheckForMisbehaviour(clientMsg lightclient.ClientMessage) bool {
	switch msg := clientMsg.(type) {
	case *MsgHeader:
		consState := msg.ConsensusState()
		// Check if the Client store already has a consensus state for the header's
		// height.
		// If the consensus state exists, and it matches the header then we return
		// early since header has already been submitted in a previous
		// UpdateClient.
		if existingConsState, found := tm.GetConsensusState(msg.GetHeight()); found {
			// This header has already been submitted and the necessary state is
			// already stored in client store, thus we can return early without
			// further validation.
			if existingConsState.Equal(consState) {
				return false
			}
			// A consensus state already exists for this height, but it does not
			// match the provided header. The assumption is that Header has already
			// been validated. Thus we can return true as misbehaviour is present
			return true
		}

		// Check that consensus state timestamps are monotonic
		prevCons, prevOk := tm.GetPreviousConsensusState(msg.GetHeight())
		nextCons, nextOk := tm.GetNextConsensusState(msg.GetHeight())
		// if previous consensus state exists, check consensus state time is
		// greater than previous consensus state time if previous consensus state
		// is not before current consensus state return true
		if prevOk && !prevCons.Timestamp.Before(consState.Timestamp) {
			return true
		}
		// if next consensus state exists, check consensus state time is less than
		// next consensus state time if next consensus state is not after current
		// consensus state return true
		if nextOk && !nextCons.Timestamp.After(consState.Timestamp) {
			return true
		}

	case *Misbehaviour:
		// if heights are equal check that this is valid misbehaviour of a fork
		// otherwise if heights are unequal check that this is valid misbehavior of
		// BFT time violation.
		if msg.Header1.GetHeight().EQ(msg.Header2.GetHeight()) {
			// Ensure that Commit Hashes are different
			if !bytes.Equal(
				msg.Header1.Commit.BlockID.Hash,
				msg.Header2.Commit.BlockID.Hash,
			) {
				return true
			}
		} else if !msg.Header1.Header.Time.After(msg.Header2.Header.Time) {
			// Header1 is at greater height than Header2 (ensured by
			// Misbehaviour.ValidateBasic()), therefore Header1 time must be less
			// than or equal to Header2 time in order to be valid misbehaviour
			// (violation of monotonic time).
			return true
		}
	}
	return false
}

// FrozenHeight is same for all misbehaviour
var FrozenHeight = types.NewHeight(0, 1)

// Implements lightclient.Interface
func (tm *TMLightClient) UpdateStateOnMisbehaviour(clientMsg lightclient.ClientMessage) {
	tm.ClientState.FrozenHeight = FrozenHeight
}

// Implements lightclient.Interface
func (tm *TMLightClient) UpdateState(clientMsg lightclient.ClientMessage) []types.Height {
	msg, ok := clientMsg.(*MsgHeader)
	if !ok {
		// clientMsg is an invalid Misbehaviour, no update necessary
		return []types.Height{}
	}

	// check for duplicate update
	msgHeight := msg.GetHeight()
	if tm.HasConsensusState(msgHeight) {
		// perform no-op
		return []types.Height{msgHeight}
	}
	// Update latestHeight if required
	if msgHeight.GT(tm.ClientState.LatestHeight) {
		tm.ClientState.LatestHeight = msgHeight
	}
	// Build and store new consensus state from clientMsg
	consState := &ConsensusState{
		Timestamp:          msg.Header.Time,
		Root:               NewMerkleRoot(msg.Header.AppHash),
		NextValidatorsHash: msg.Header.NextValidatorsHash,
		processedTime:      time.Now(),
		processedHeight:    types.GetSelfHeight(),
	}
	tm.SetConsensusState(msgHeight, consState)
	return []types.Height{msgHeight}
}

// Implements lightclient.Interface
func (tm *TMLightClient) VerifyMembership(height types.Height,
	proofs []ics23.CommitmentProof, path types.MerklePath,
	value []byte) error {
	if tm.ClientState.LatestHeight.LT(height) {
		return ufmt.Errorf(
			"client state height < proof height (%s < %s), please ensure the client has been updated", tm.ClientState.LatestHeight, height,
		)
	}
	if len(value) == 0 {
		return ufmt.Errorf("empty value in membership proof")
	}
	if len(tm.ClientState.ProofSpecs) != len(proofs) {
		return ufmt.Errorf(
			"length of specs: %d not equal to length of proof: %d",
			len(tm.ClientState.ProofSpecs), len(proofs),
		)
	}
	if len(path.KeyPath) != len(proofs) {
		return ufmt.Errorf(
			"path length %d not same as proof %d", len(path.KeyPath), len(proofs),
		)
	}
	consState, found := tm.GetConsensusState(height)
	if !found {
		return ufmt.Errorf("please ensure the proof was constructed against a height that exists on the client")
	}
	return tm.verifyChainedMembershipProof(consState.Root.Hash, proofs, path, value, 0)
}

// Implements lightclient.Interface
func (tm *TMLightClient) VerifyNonMembership(height types.Height,
	proofs []ics23.CommitmentProof, path types.MerklePath) error {
	if tm.ClientState.LatestHeight.LT(height) {
		return ufmt.Errorf(
			"client state height < proof height (%d < %d), please ensure the client has been updated", tm.ClientState.LatestHeight, height,
		)
	}
	if len(tm.ClientState.ProofSpecs) != len(proofs) {
		return ufmt.Errorf(
			"length of specs: %d not equal to length of proof: %d",
			len(tm.ClientState.ProofSpecs), len(proofs),
		)
	}
	if len(path.KeyPath) != len(proofs) {
		return ufmt.Errorf(
			"path length %d not same as proof %d", len(path.KeyPath), len(proofs),
		)
	}

	consState, found := tm.GetConsensusState(height)
	if !found {
		return ufmt.Errorf("please ensure the proof was constructed against a height that exists on the client")
	}
	// VerifyNonMembership will verify the absence of key in lowest subtree, and
	// then chain inclusion proofs of all subroots up to final root.
	nonexist := proofs[0].GetNonexist()
	if nonexist == nil {
		return ufmt.Errorf("commitment proof must be non-existence proof for verifying non-membership")
	}
	subroot, err := nonexist.Calculate()
	if err != nil {
		return ufmt.Errorf("could not calculate root for proof index 0, merkle tree is likely empty. %v", err)
	}

	key := path.KeyPath[len(path.KeyPath)-1]
	if err := nonexist.Verify(tm.ClientState.ProofSpecs[0], subroot, key); err != nil {
		return ufmt.Errorf("failed to verify non-membership proof with key %s: %v", string(key), err)
	}

	// Verify chained membership proof starting from index 1 with value = subroot
	return tm.verifyChainedMembershipProof(consState.Root.Hash, proofs, path, subroot, 1)
}

// Implements lightclient.Interface
func (tm *TMLightClient) Status() lightclient.Status {
	if !tm.ClientState.FrozenHeight.IsZero() {
		return lightclient.Frozen
	}
	// get latest consensus state to check for expiry
	lastConsState, found := tm.GetConsensusState(tm.LatestHeight())
	if !found {
		// if the client state does not have an associated consensus state for its
		// latest height then it must be expired
		return lightclient.Expired
	}
	if tm.IsExpired(lastConsState.Timestamp, time.Now()) {
		return lightclient.Expired
	}
	return lightclient.Active
}

// Implements lightclient.Interface
func (tm *TMLightClient) LatestHeight() types.Height {
	return tm.ClientState.LatestHeight
}

// Implements lightclient.Interface
func (tm *TMLightClient) TimestampAtHeight(height types.Height) (uint64, error) {
	cs, found := tm.GetConsensusState(height)
	if !found {
		return 0, ufmt.Errorf("no consensus state found for height %s", height.String())
	}
	return uint64(cs.Timestamp.Unix()), nil
}

// Implements lightclient.Interface.
//
// RecoverClient copies the substitute's consensus state at its latest height
// into the subject (tm), updates the subject's ChainID, LatestHeight and
// TrustingPeriod to match the substitute, and un-freezes the subject by
// resetting FrozenHeight. The substitute and subject client states must match
// in TrustLevel, UnbondingPeriod, MaxClockDrift, ProofSpecs and UpgradePath.
func (tm *TMLightClient) RecoverClient(substitute lightclient.Interface) error {
	if substitute == nil {
		return errors.New("substitute must not be nil")
	}
	sub, ok := substitute.(*TMLightClient)
	if !ok {
		return ufmt.Errorf("substitute client type mismatch: expected *TMLightClient, got %T", substitute)
	}
	if field := mismatchingClientStateField(tm.ClientState, sub.ClientState); field != "" {
		return ufmt.Errorf("subject and substitute client states differ on %s", field)
	}
	subLatest := sub.ClientState.LatestHeight
	subConsState, found := sub.GetConsensusState(subLatest)
	if !found {
		return ufmt.Errorf("substitute consensus state not found at height %s", subLatest)
	}

	tm.ClientState.ChainID = sub.ClientState.ChainID
	tm.ClientState.LatestHeight = subLatest
	tm.ClientState.TrustingPeriod = sub.ClientState.TrustingPeriod
	tm.ClientState.FrozenHeight = types.ZeroHeight()
	tm.SetConsensusState(subLatest, subConsState)
	return nil
}

// mismatchingClientStateField returns the name of the first client-state field
// that differs between subject and substitute, or an empty string if all
// parameters that must not change during a client recovery match. ChainID,
// LatestHeight, FrozenHeight and TrustingPeriod are allowed to differ — the
// substitute's TrustingPeriod is adopted by the subject.
func mismatchingClientStateField(subject, substitute *ClientState) string {
	if subject.TrustLevel != substitute.TrustLevel {
		return "TrustLevel"
	}
	if subject.UnbondingPeriod != substitute.UnbondingPeriod {
		return "UnbondingPeriod"
	}
	if subject.MaxClockDrift != substitute.MaxClockDrift {
		return "MaxClockDrift"
	}
	if len(subject.ProofSpecs) != len(substitute.ProofSpecs) {
		return "ProofSpecs"
	}
	for i := range subject.ProofSpecs {
		if !subject.ProofSpecs[i].Equal(substitute.ProofSpecs[i]) {
			return "ProofSpecs"
		}
	}
	if len(subject.UpgradePath) != len(substitute.UpgradePath) {
		return "UpgradePath"
	}
	for i := range subject.UpgradePath {
		if subject.UpgradePath[i] != substitute.UpgradePath[i] {
			return "UpgradePath"
		}
	}
	return ""
}

// Implements lightclient.Interface
func (tm *TMLightClient) VerifyUpgradeAndUpdateState(newClient, newConsState any,
	upgradeClientProof, upgradeConsensusStateProof any) error {
	upgradedClientState, ok := newClient.(ClientState)
	if !ok {
		return ufmt.Errorf("upgraded client state must be tendermint.ClientState, got %T", newClient)
	}
	if err := upgradedClientState.ValidateBasic(); err != nil {
		return ufmt.Errorf("invalid upgraded client state: %v", err)
	}

	upgradedConsensusState, ok := newConsState.(ConsensusState)
	if !ok {
		return ufmt.Errorf("upgraded consensus state must be tendermint.ConsensusState, got %T", newConsState)
	}
	if err := upgradedConsensusState.ValidateBasic(); err != nil {
		return ufmt.Errorf("invalid upgraded consensus state: %v", err)
	}

	if !upgradedClientState.LatestHeight.GT(tm.ClientState.LatestHeight) {
		return ufmt.Errorf(
			"upgraded client latest height (%s) must be greater than current latest height (%s)",
			upgradedClientState.LatestHeight, tm.ClientState.LatestHeight,
		)
	}

	lastHeight := tm.ClientState.LatestHeight

	clientProofs, ok := upgradeClientProof.([]ics23.CommitmentProof)
	if !ok {
		return ufmt.Errorf("upgradeClientProof must be []ics23.CommitmentProof, got %T", upgradeClientProof)
	}
	if len(clientProofs) == 0 {
		return errors.New("upgradeClientProof cannot be empty")
	}

	consensusProofs, ok := upgradeConsensusStateProof.([]ics23.CommitmentProof)
	if !ok {
		return ufmt.Errorf("upgradeConsensusStateProof must be []ics23.CommitmentProof, got %T", upgradeConsensusStateProof)
	}
	if len(consensusProofs) == 0 {
		return errors.New("upgradeConsensusStateProof cannot be empty")
	}

	path := tm.ClientState.UpgradePath
	clientPath := buildUpgradeMerklePath(path, "upgradedClient", lastHeight)
	// The counterparty chain commits to the upgraded client with all
	// customizable fields zeroed, so we must verify the proof against the
	// same shape.
	clientValue := upgradedClientState.ZeroCustomFields().ProtoMarshal()
	if err := tm.VerifyMembership(lastHeight, clientProofs, clientPath, clientValue); err != nil {
		return ufmt.Errorf("failed to verify upgrade client proof: %v", err)
	}

	consensusPath := buildUpgradeMerklePath(path, "upgradedConsensusState", lastHeight)
	consensusValue := upgradedConsensusState.ProtoMarshal()
	if err := tm.VerifyMembership(lastHeight, consensusProofs, consensusPath, consensusValue); err != nil {
		return ufmt.Errorf("failed to verify upgrade consensus state proof: %v", err)
	}

	// Construct the new client by combining chain-specified fields from the
	// upgraded client (ChainID, UnbondingPeriod, LatestHeight, ProofSpecs,
	// UpgradePath) with the customizable fields preserved from the current
	// client (TrustLevel, TrustingPeriod, MaxClockDrift). FrozenHeight is
	// reset on a successful upgrade. If the unbonding period shrinks, the
	// trusting period is scaled proportionally to maintain the security
	// ratio.
	trustingPeriod := tm.ClientState.TrustingPeriod
	if upgradedClientState.UnbondingPeriod < tm.ClientState.UnbondingPeriod {
		trustingPeriod = calculateNewTrustingPeriod(
			trustingPeriod, tm.ClientState.UnbondingPeriod, upgradedClientState.UnbondingPeriod,
		)
	}
	newClientState := &ClientState{
		ChainID:         upgradedClientState.ChainID,
		TrustLevel:      tm.ClientState.TrustLevel,
		TrustingPeriod:  trustingPeriod,
		UnbondingPeriod: upgradedClientState.UnbondingPeriod,
		MaxClockDrift:   tm.ClientState.MaxClockDrift,
		FrozenHeight:    types.ZeroHeight(),
		LatestHeight:    upgradedClientState.LatestHeight,
		ProofSpecs:      upgradedClientState.ProofSpecs,
		UpgradePath:     upgradedClientState.UpgradePath,
	}
	if err := newClientState.ValidateBasic(); err != nil {
		return ufmt.Errorf("upgraded client state failed basic validation: %v", err)
	}

	tm.ClientState = newClientState
	// The upgraded consensus state is committed before the new chain
	// produces any blocks, so its Root is a placeholder. Overwrite it with
	// the well-known sentinel value so this consensus state cannot be used
	// to verify packet proofs — real Roots arrive later via UpdateClient.
	upgradedConsensusState.Root = NewMerkleRoot([]byte(SentinelRoot))
	upgradedConsensusState.processedTime = time.Now()
	upgradedConsensusState.processedHeight = types.GetSelfHeight()
	tm.SetConsensusState(newClientState.LatestHeight, &upgradedConsensusState)

	return nil
}

// calculateNewTrustingPeriod scales the trusting period proportionally to a
// shorter unbonding period: newTrusting = trusting * newUnbonding /
// currentUnbonding (with truncation). The math is performed in seconds to
// stay within int64 range for realistic chain values; sub-second precision
// is irrelevant for IBC trusting periods, which are measured in days.
func calculateNewTrustingPeriod(trustingPeriod, currentUnbondingPeriod, newUnbondingPeriod time.Duration) time.Duration {
	currentSec := int64(currentUnbondingPeriod / time.Second)
	if currentSec == 0 {
		return 0
	}
	trustingSec := int64(trustingPeriod / time.Second)
	newUnbondingSec := int64(newUnbondingPeriod / time.Second)
	return time.Duration(trustingSec*newUnbondingSec/currentSec) * time.Second
}

func buildUpgradeMerklePath(path []string, lastKey string, height types.Height) types.MerklePath {
	if len(path) == 0 {
		return types.MerklePath{KeyPath: [][]byte{[]byte(lastKey)}}
	}
	lastPathElement := path[len(path)-1]
	prefixPath := path[:len(path)-1]
	mergedPath := ""
	for i, k := range prefixPath {
		mergedPath += k
		if i < len(prefixPath)-1 {
			mergedPath += "/"
		}
	}
	appendedKey := ufmt.Sprintf("%s/%d/%s", lastPathElement, height.RevisionHeight, lastKey)
	return types.MerklePath{KeyPath: [][]byte{[]byte(mergedPath), []byte(appendedKey)}}
}

func (tm *TMLightClient) SetConsensusState(height types.Height, consState *ConsensusState) {
	tm.ConsensusStateByHeight.Set(height.StringNatSort(), consState)
}

func (tm *TMLightClient) HasConsensusState(height types.Height) bool {
	return tm.ConsensusStateByHeight.Has(height.StringNatSort())
}

// GetConsensusState returns the consensus state mapped at height, if any.
func (tm *TMLightClient) GetConsensusState(height types.Height) (*ConsensusState, bool) {
	x, found := tm.ConsensusStateByHeight.Get(height.StringNatSort())
	if !found {
		return nil, false
	}
	return x.(*ConsensusState), true
}

// GetNextConsensusState returns the lowest consensus state that is larger than
// the given height.
func (tm *TMLightClient) GetNextConsensusState(height types.Height) (*ConsensusState, bool) {
	var cs *ConsensusState
	tm.ConsensusStateByHeight.Iterate(height.StringNatSort(), "", func(k string, v any) bool {
		if k == height.StringNatSort() {
			return false // ignore passed height
		}
		cs = v.(*ConsensusState)
		return true
	})
	return cs, cs != nil
}

// GetPreviousConsensusState returns the highest consensus state that is lower
// than the given height.
func (tm *TMLightClient) GetPreviousConsensusState(height types.Height) (*ConsensusState, bool) {
	var cs *ConsensusState
	tm.ConsensusStateByHeight.ReverseIterate("", height.StringNatSort(), func(k string, v any) bool {
		if k == height.StringNatSort() {
			return false // ignore passed height
		}
		cs = v.(*ConsensusState)
		return true
	})
	return cs, cs != nil
}

// IsExpired returns whether or not the client has passed the trusting period
// since the last update (in which case no headers are considered valid).
func (tm *TMLightClient) IsExpired(latestTimestamp, now time.Time) bool {
	expirationTime := latestTimestamp.Add(tm.ClientState.TrustingPeriod)
	return !expirationTime.After(now)
}
