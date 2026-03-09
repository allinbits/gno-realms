package tendermint

import (
	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/nt/ufmt/v0"
)

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
	if m.Header1 == nil {
		return ufmt.Errorf("misbehaviour Header1 cannot be nil")
	}
	if m.Header2 == nil {
		return ufmt.Errorf("misbehaviour Header2 cannot be nil")
	}
	if m.Header1.TrustedHeight.RevisionHeight == 0 {
		return ufmt.Errorf("misbehaviour Header1 cannot have zero revision height")
	}
	if m.Header2.TrustedHeight.RevisionHeight == 0 {
		return ufmt.Errorf("misbehaviour Header2 cannot have zero revision height")
	}
	if m.Header1.TrustedValidators == nil {
		return ufmt.Errorf("trusted validator set in Header1 cannot be empty")
	}
	if m.Header2.TrustedValidators == nil {
		return ufmt.Errorf("trusted validator set in Header2 cannot be empty")
	}
	if m.Header1.Header.ChainID != m.Header2.Header.ChainID {
		return ufmt.Errorf("headers must have identical chainIDs")
	}

	// ValidateBasic on both validators
	if err := m.Header1.ValidateBasic(); err != nil {
		return ufmt.Errorf("header 1 failed validation: %v", err)
	}
	if err := m.Header2.ValidateBasic(); err != nil {
		return ufmt.Errorf("header 2 failed validation: %v", err)
	}
	// Ensure that Height1 is greater than or equal to Height2
	if m.Header1.GetHeight().LT(m.Header2.GetHeight()) {
		return ufmt.Errorf("Header1 height is less than Header2 height (%s < %s)", m.Header1.GetHeight(), m.Header2.GetHeight())
	}

	if err := validateCommit(m.Header1); err != nil {
		return ufmt.Errorf("invalid header1 commit: %v", err)
	}
	if err := validateCommit(m.Header2); err != nil {
		return ufmt.Errorf("invalid header2 commit: %v", err)
	}
	return nil
}

// validateCommit checks if the given commit is a valid commit from the
// passed-in MsgHeader.
func validateCommit(msg *MsgHeader) error {
	votingPowerNeeded := msg.ValidatorSet.TotalVotingPower * 2 / 3
	if err := verifyCommit(msg.Header.ChainID, msg.ValidatorSet, msg.Commit, votingPowerNeeded, true); err != nil {
		return ufmt.Errorf("validator set did not commit to header: %v", err)
	}
	return nil
}
