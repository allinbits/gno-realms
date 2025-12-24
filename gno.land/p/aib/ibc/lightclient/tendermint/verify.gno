package tendermint

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"time"

	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/ufmt"
)

func (tm *TMLightClient) verifyHeader(msg *MsgHeader) error {
	// Retrieve trusted consensus states for trusted height
	consState, found := tm.GetConsensusState(msg.TrustedHeight)
	if !found {
		return ufmt.Errorf("could not get trusted consensus state for Header at TrustedHeight: %s", msg.TrustedHeight)
	}

	// UpdateClient only accepts updates with a header at the same revision
	// as the trusted consensus state
	if msg.GetHeight().RevisionNumber != msg.TrustedHeight.RevisionNumber {
		return ufmt.Errorf(
			"header height revision %d does not match trusted header revision %d",
			msg.GetHeight().RevisionNumber, msg.TrustedHeight.RevisionNumber,
		)
	}
	if err := checkTrustedHeader(msg, consState); err != nil {
		return err
	}

	var (
		now             = time.Now()
		untrustedHeader = msg.Header
		untrustedValset = msg.ValidatorSet
		chainID         = tm.ClientState.ChainID
		trustedHeader   = &Header{
			ChainID:            chainID,
			Height:             msg.TrustedHeight.RevisionHeight,
			Time:               consState.Timestamp,
			NextValidatorsHash: consState.NextValidatorsHash,
		}
		trustedValset = msg.TrustedValidators
	)

	// UpdateClient only accepts updates with a header at the same revision
	// as the trusted consensus state
	if untrustedHeader.ChainID != trustedHeader.ChainID {
		return ufmt.Errorf("header belongs to another chain %q, not %q",
			untrustedHeader.ChainID, trustedHeader.ChainID)
	}

	if !untrustedHeader.Time.After(trustedHeader.Time) {
		return ufmt.Errorf(
			"expected new header time %v to be after old header time %v",
			untrustedHeader.Time, trustedHeader.Time,
		)
	}

	if !untrustedHeader.Time.Before(now.Add(tm.ClientState.MaxClockDrift)) {
		return ufmt.Errorf(
			"new header has a time from the future %v (now: %v; max clock drift: %v)",
			untrustedHeader.Time, now, tm.ClientState.MaxClockDrift,
		)
	}

	if err := trustedHeader.Expired(tm.ClientState.TrustingPeriod); err != nil {
		return err
	}

	if untrustedHeader.Height == trustedHeader.Height+1 {
		// Adjacent heights, check the validator hashes are the same
		if !bytes.Equal(untrustedHeader.ValidatorsHash, trustedHeader.NextValidatorsHash) {
			h1, h2 := hex.EncodeToString(trustedHeader.NextValidatorsHash), hex.EncodeToString(untrustedHeader.ValidatorsHash)
			return ufmt.Errorf(
				"expected old header next validators (%s) to match those from new header (%s)",
				h1, h2,
			)
		}
	} else {
		// Heights aren't adjacent, this requires to check if at least trustlevel
		// ([1/3, 1]) of trusted validators have signed correctly.
		var (
			tl                = tm.ClientState.TrustLevel
			votingPowerNeeded = trustedValset.TotalVotingPower *
				int64(tl.Numerator) / int64(tl.Denominator)
		)
		if err := verifyCommit(chainID, trustedValset, msg.Commit, votingPowerNeeded, false); err != nil {
			return ufmt.Errorf("check trusted validators VP>%d: %v", votingPowerNeeded, err)
		}
	}
	// Ensure that +2/3 of untrustedValset signed correctly.
	//
	// NOTE: this should always be the last check because untrustedValset can be
	// intentionally made very large to DOS the light client.
	votingPowerNeeded := untrustedValset.TotalVotingPower * 2 / 3
	err := verifyCommit(chainID, untrustedValset, msg.Commit, votingPowerNeeded, true)
	if err != nil {
		return ufmt.Errorf("check untrusted validators VP>%d: %v", votingPowerNeeded, err)
	}
	return nil
}

// verifyMisbehaviour determines whether or not two conflicting headers at the
// same height would have convinced the light client.
func (tm TMLightClient) verifyMisbehavior(misbehaviour *Misbehaviour) error {
	// Regardless of the type of misbehaviour, ensure that both headers are valid
	// and would have been accepted by light-client

	// Retrieve trusted consensus states for each Header in misbehaviour
	tmConsensusState1, found := tm.GetConsensusState(misbehaviour.Header1.TrustedHeight)
	if !found {
		return ufmt.Errorf(
			"could not get trusted consensus state from clientStore for Header1 at TrustedHeight: %s",
			misbehaviour.Header1.TrustedHeight,
		)
	}

	tmConsensusState2, found := tm.GetConsensusState(misbehaviour.Header2.TrustedHeight)
	if !found {
		return ufmt.Errorf(
			"could not get trusted consensus state from clientStore for Header2 at TrustedHeight: %s",
			misbehaviour.Header2.TrustedHeight,
		)
	}

	// Check the validity of the two conflicting headers against their respective
	// trusted consensus states.
	if err := tm.checkMisbehaviourHeader(tmConsensusState1, misbehaviour.Header1, time.Now()); err != nil {
		return ufmt.Errorf("verifying Header1 in Misbehaviour failed: %v", err)
	}
	if err := tm.checkMisbehaviourHeader(tmConsensusState2, misbehaviour.Header2, time.Now()); err != nil {
		return ufmt.Errorf("verifying Header2 in Misbehaviour failed: %v", err)
	}

	return nil
}

// checkTrustedHeader checks that consensus state matches trusted fields of Header
func checkTrustedHeader(msg *MsgHeader, consensusState *ConsensusState) error {
	tvalHash := msg.TrustedValidators.Hash()
	if !bytes.Equal(consensusState.NextValidatorsHash, tvalHash) {
		h1, h2 := hex.EncodeToString(consensusState.NextValidatorsHash), hex.EncodeToString(tvalHash)
		return ufmt.Errorf(
			"trusted validators do not hash to latest trusted validators. Expected: %q, got: %q",
			h1, h2,
		)
	}
	return nil
}

// verifyCommit verifies the signatures included in a commit. Returns an error
// if votingPowerNeeded is not reached with the verified signatures.
// CONTRACT: both commit and validator set should have passed validate basic.
func verifyCommit(
	chainID string,
	vals *ValidatorSet,
	commit *Commit,
	votingPowerNeeded int64,
	lookUpByIndex bool,
) error {
	var (
		val                *Validator
		valIdx             int32
		seenVals           = make(map[int32]int, len(commit.Signatures))
		talliedVotingPower int64
	)
	for idx, commitSig := range commit.Signatures {
		if commitSig.BlockIDFlag != BlockIDFlagCommit {
			continue
		}

		// If the vals and commit have a 1-to-1 correspondence we can retrieve
		// them by index else we need to retrieve them by address
		if lookUpByIndex {
			val = vals.Validators[idx]
		} else {
			valIdx, val = vals.GetByAddress(commitSig.ValidatorAddress)

			// if the signature doesn't belong to anyone in the validator set
			// then we just skip over it
			if val == nil {
				continue
			}

			// because we are getting validators by address we need to make sure
			// that the same validator doesn't commit twice
			if firstIndex, ok := seenVals[valIdx]; ok {
				secondIndex := idx
				addr := hex.EncodeToString(val.Address)
				return ufmt.Errorf("double vote from %s (%d and %d)", addr, firstIndex, secondIndex)
			}
			seenVals[valIdx] = idx
		}

		if len(val.PubKey) == 0 {
			addr := hex.EncodeToString(val.Address)
			return ufmt.Errorf("validator %s has a nil PubKey at index %d", addr, idx)
		}

		voteSignBytes := commit.BytesToSign(chainID, idx)

		// CONTRACT: all validators use ed25519 keys
		if !ed25519.Verify(val.PubKey, voteSignBytes, commitSig.Signature) {
			return ufmt.Errorf("verify signature fail (#%d)", idx)
		}

		talliedVotingPower += val.VotingPower

		// check if we have enough signatures and can thus exit early
		if talliedVotingPower > votingPowerNeeded {
			return nil
		}
	}
	return ufmt.Errorf(
		"not enough voting power, got %v, needed >%v",
		talliedVotingPower, votingPowerNeeded,
	)
}

// verifyChainedMembershipProof takes a list of proofs and specs and verifies
// each proof sequentially ensuring that the value is committed to by first
// proof and each subsequent subroot is committed to by the next subroot and
// checking that the final calculated root is equal to the given roothash.
// The proofs and specs are passed in from lowest subtree to the highest
// subtree, but the keys are passed in from highest subtree to lowest.
// The index specifies what index to start chaining the membership proofs, this
// is useful since the lowest proof may not be a membership proof, thus we will
// want to start the membership proof chaining from index 1 with value being
// the lowest subroot
func (tm TMLightClient) verifyChainedMembershipProof(root []byte,
	proofs []ics23.CommitmentProof, keys types.MerklePath, value []byte,
	index int) error {
	var (
		specs   = tm.ClientState.ProofSpecs
		subroot []byte
		err     error
	)
	// Initialize subroot to value since the proofs list may be empty.
	// This may happen if this call is verifying intermediate proofs after the
	// lowest proof has been executed.
	// In this case, there may be no intermediate proofs to verify and we just
	// check that lowest proof root equals final root
	subroot = value
	for i := index; i < len(proofs); i++ {
		// verify membership of the proof at this index with appropriate key and
		// value
		exist := proofs[i].GetExist()
		if exist == nil {
			return ufmt.Errorf("commitment proof must be existence proof for verifying membership")
		}
		subroot, err = exist.Calculate()
		if err != nil {
			return ufmt.Errorf("could not calculate proof root at index %d, merkle tree may be empty. %v", i, err)
		}

		// Since keys are passed in from highest to lowest, we must grab their
		// indices in reverse order from the proofs and specs which are lowest to
		// highest
		key := keys.KeyPath[len(keys.KeyPath)-1-i]

		if err := exist.Verify(specs[i], subroot, key, value); err != nil {
			return ufmt.Errorf("failed to verify membership proof at index %d: %v", i, err)
		}
		// Set value to subroot so that we verify next proof in chain commits to
		// this subroot
		value = subroot
	}

	// Check that chained proof root equals passed-in root
	if !bytes.Equal(root, subroot) {
		h1, h2 := hex.EncodeToString(root), hex.EncodeToString(subroot)
		return ufmt.Errorf("proof did not commit to expected root: %s, got: %s. Please ensure proof was submitted with correct proofHeight and to the correct chain.", h1, h2)
	}

	return nil
}

// checkMisbehaviourHeader checks that a MsgHeader in Misbehaviour is valid
// misbehaviour given a trusted ConsensusState.
func (tm TMLightClient) checkMisbehaviourHeader(
	consState *ConsensusState, msg *MsgHeader, currentTimestamp time.Time,
) error {
	// check the trusted fields for the header against ConsensusState
	if err := checkTrustedHeader(msg, consState); err != nil {
		return err
	}

	// assert that the age of the trusted consensus state is not older than the
	// trusting period
	if currentTimestamp.Sub(consState.Timestamp) >= tm.ClientState.TrustingPeriod {
		return ufmt.Errorf(
			"current timestamp minus the latest consensus state timestamp is greater than or equal to the trusting period (%d >= %d)",
			currentTimestamp.Sub(consState.Timestamp), tm.ClientState.TrustingPeriod,
		)
	}

	chainID := tm.ClientState.ChainID
	// If chainID is in revision format, then set revision number of chainID with
	// the revision number of the misbehaviour header.
	// NOTE: misbehaviour verification is not supported for chains which upgrade
	// to a new chainID without strictly following the chainID revision format.
	if types.IsRevisionFormat(chainID) {
		chainID, _ = types.SetRevisionNumber(chainID, msg.GetHeight().RevisionNumber)
	}

	// - ValidatorSet must have TrustLevel similarity with trusted FromValidatorSet
	// - ValidatorSets on both headers are valid given the last trusted ValidatorSet
	var (
		tl = tm.ClientState.TrustLevel
		// TODO protect against overflows
		votingPowerNeeded = msg.TrustedValidators.TotalVotingPower *
			int64(tl.Numerator) / int64(tl.Denominator)
	)
	if err := verifyCommit(chainID, msg.TrustedValidators, msg.Commit, votingPowerNeeded, false); err != nil {
		return ufmt.Errorf("validator set in header has too much change from trusted validator set: %v", err)
	}
	return nil
}
