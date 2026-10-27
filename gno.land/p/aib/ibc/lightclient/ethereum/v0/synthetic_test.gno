package ethereum

import (
	"bytes"
	"testing"

	"gno.land/p/nt/urequire/v0"
)

// The synthetic data (zz_synthetic_test.gno) is built by cmd/gen-eth-synthetic
// from the consensus specs and signed with blst, independently of this
// package: these tests check the client against it.

// syntheticClient is a client at the synthetic trusted state, its clock a
// slot after the latest synthetic signature slot (161).
func syntheticClient(t *testing.T) *EthLightClient {
	cs := syntheticClientState()
	urequire.NoError(t, cs.ValidateBasic())
	cons := syntheticConsensusState()
	urequire.NoError(t, cons.ValidateBasic())
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	setNow(cs.GenesisTime + 162*cs.SecondsPerSlot)
	return c
}

// applySynthetic verifies and applies hdr, then checks the state it stores:
// the finalized execution block's root, timestamp and number, and the next
// committee it reveals.
func applySynthetic(t *testing.T, hdr *Header) {
	c := syntheticClient(t)
	urequire.NoError(t, hdr.ValidateBasic())
	urequire.NoError(t, c.VerifyClientMessage(hdr))
	urequire.False(t, c.CheckForMisbehaviour(hdr))
	heights := c.UpdateState(hdr)
	urequire.Equal(t, 1, len(heights))
	urequire.Equal(t, uint64(136), c.ClientState.LatestSlot)

	root, ts, number := syntheticFinalizedExecution()
	cons, ok := c.GetConsensusState(heightAtSlot(136))
	urequire.True(t, ok)
	urequire.True(t, bytes.Equal(root, cons.StateRoot), "the finalized block's state root")
	urequire.Equal(t, ts, cons.Timestamp)
	urequire.Equal(t, syntheticClientState().GenesisTime+136*2, ts) // the finalized Fulu payload's own slot time
	urequire.Equal(t, number, c.ClientState.LatestExecutionBlockNumber)
	next := syntheticNextCommittee()
	urequire.True(t, cons.NextSyncCommittee != nil && cons.NextSyncCommittee.equal(next), "the revealed next committee")
	urequire.True(t, cons.CurrentSyncCommittee.equal(syntheticConsensusState().CurrentSyncCommittee))
}

// A canonical Gloas update: attested at slot 160 (gindices 735 and 2946,
// execution block hash at 2856) and signed under the Gloas domain (signature
// slot 161, domain at 160), whose finalized header is still Fulu, upgraded to
// the block-hash form (gindex 812, an 11-node normalized branch) with its full
// RLP execution header, from which the client takes the execution data.
func TestSyntheticGloasTransition(t *testing.T) {
	c := syntheticClient(t)
	hdr := syntheticGloasTransition()
	u := hdr.ConsensusUpdate
	urequire.True(t, c.ClientState.isGloas(u.AttestedHeader.Beacon.Slot))
	urequire.False(t, c.ClientState.isGloas(u.FinalizedHeader.Beacon.Slot))
	urequire.True(t, u.FinalizedHeader.hashForm())
	urequire.Equal(t, 11, len(u.FinalizedHeader.ExecutionBranch))
	applySynthetic(t, hdr)

	bad := syntheticGloasTransition()
	bad.ConsensusUpdate.FinalizedExecutionHeader = flip(bad.ConsensusUpdate.FinalizedExecutionHeader, 100)
	urequire.ErrorContains(t, syntheticClient(t).VerifyClientMessage(bad), "finalized execution header does not match the execution block hash")
}

// A client-compatibility case outside the spec: the Gloas update with its
// Fulu finalized header left in the payload form (gindex 25), which a Gloas
// LightClientHeader cannot hold but this client accepts, verifying each
// header's execution against its own slot's fork.
func TestSyntheticMixedFormTransition(t *testing.T) {
	hdr := syntheticMixedFormTransition()
	urequire.False(t, hdr.ConsensusUpdate.FinalizedHeader.hashForm())
	applySynthetic(t, hdr)
}

// A Fulu update: attested at slot 152 (gindices 169 and 87) and signed under
// the Fulu domain, both headers with their execution payload header at gindex
// 25.
func TestSyntheticFuluUpdate(t *testing.T) {
	c := syntheticClient(t)
	hdr := syntheticFuluUpdate()
	u := hdr.ConsensusUpdate
	urequire.False(t, c.ClientState.isGloas(u.AttestedHeader.Beacon.Slot))
	urequire.False(t, c.ClientState.isGloas(u.SignatureSlot-1))
	urequire.False(t, u.AttestedHeader.hashForm() || u.FinalizedHeader.hashForm())
	applySynthetic(t, hdr)
}

// A fully valid conflicting-finality pair: verified, checked, it freezes the
// client.
func TestSyntheticMisbehaviour(t *testing.T) {
	c := syntheticClient(t)
	m := syntheticMisbehaviour()
	urequire.NoError(t, m.ValidateBasic())
	urequire.NoError(t, c.VerifyClientMessage(m))
	urequire.True(t, c.CheckForMisbehaviour(m))
	c.UpdateStateOnMisbehaviour(m)
	urequire.Equal(t, "Frozen", string(c.Status()))

	// Either update with a forged signature voids the evidence.
	for i, name := range []string{"update 1:", "update 2:"} {
		m := syntheticMisbehaviour()
		u := &m.Update1
		if i == 1 {
			u = &m.Update2
		}
		u.SyncAggregate.SyncCommitteeSignature = syntheticOutsiderSignature()
		urequire.ErrorContains(t, syntheticClient(t).VerifyClientMessage(m), name+" invalid sync committee signature")
	}
}

// An update with three non-signers verifies; the non-signers reordered,
// proven at another index, or one missing are refused, and so is a signature
// with a share by a key outside the committee.
func TestSyntheticNonSigners(t *testing.T) {
	hdr := syntheticNonSigners()
	urequire.Equal(t, 3, len(hdr.ConsensusUpdate.NonSigners))
	urequire.NoError(t, syntheticClient(t).VerifyClientMessage(hdr))

	cases := []struct {
		name   string
		mutate func(u *LightClientUpdate)
		err    string
	}{
		{"reordered", func(u *LightClientUpdate) {
			ns := append([]NonSigner{}, u.NonSigners...)
			ns[0], ns[1] = ns[1], ns[0]
			u.NonSigners = ns
		}, "invalid branch for non-signer 3"},
		{"proven at another index", func(u *LightClientUpdate) {
			// Member 3 now signs and member 4 does not, but member 3's key and
			// branch are listed for it.
			bits := append([]byte{}, u.SyncAggregate.SyncCommitteeBits...)
			bits[0] |= 1 << 3
			bits[0] &^= 1 << 4
			u.SyncAggregate.SyncCommitteeBits = bits
		}, "invalid branch for non-signer 4"},
		{"one missing", func(u *LightClientUpdate) { u.NonSigners = u.NonSigners[:2] }, "non-signer 27 is missing"},
		{"outsider's share", func(u *LightClientUpdate) {
			u.SyncAggregate.SyncCommitteeSignature = syntheticOutsiderSignature()
		}, "invalid sync committee signature"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			hdr := syntheticNonSigners()
			tc.mutate(&hdr.ConsensusUpdate)
			urequire.ErrorContains(t, syntheticClient(t).VerifyClientMessage(hdr), tc.err)
		})
	}
}
