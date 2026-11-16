// Package extproof lets light clients whose state proofs are not ICS23
// proofs (an Ethereum client proves storage with Merkle-Patricia proofs) take
// part in packet verification without changing the frozen message types.
//
// MsgRecvPacket, MsgAcknowledgement and MsgTimeout carry their proof in an
// []ics23.CommitmentProof field, which such a client cannot use, and an Ext
// field reserved for data a later core implementation needs. A relayer for
// such a client leaves the ICS23 field empty and sets Ext to a Proof; the core
// implementation then verifies through the client's Verifier methods.
package extproof

import "gno.land/p/aib/ibc/types/v0"

// Proof is the value a relayer puts in a message's Ext field to carry a
// client-specific proof. Data is whatever proof type the light client of the
// verifying side expects; the client rejects any other type.
type Proof struct {
	Data any
}

// Verifier is implemented by light clients that verify Proof.Data.
type Verifier interface {
	// VerifyMembershipProof verifies that value is stored at path at height.
	VerifyMembershipProof(height types.Height, proof any, path types.MerklePath, value []byte) error
	// VerifyNonMembershipProof verifies that nothing is stored at path at
	// height.
	VerifyNonMembershipProof(height types.Height, proof any, path types.MerklePath) error
}

// FromExt returns the Proof a message's Ext field carries, if any.
func FromExt(ext any) (Proof, bool) {
	switch p := ext.(type) {
	case Proof:
		return p, true
	case *Proof:
		if p != nil {
			return *p, true
		}
	}
	return Proof{}, false
}
