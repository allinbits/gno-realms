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
// slot after the synthetic signature slot.
func syntheticClient(t *testing.T) *EthLightClient {
	cs := syntheticClientState()
	urequire.NoError(t, cs.ValidateBasic())
	cons := syntheticConsensusState()
	urequire.NoError(t, cons.ValidateBasic())
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	setNow(cs.GenesisTime + 146*cs.SecondsPerSlot)
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
	urequire.Equal(t, number, c.ClientState.LatestExecutionBlockNumber)
	next := syntheticNextCommittee()
	urequire.True(t, cons.NextSyncCommittee != nil && cons.NextSyncCommittee.equal(next), "the revealed next committee")
	urequire.True(t, cons.CurrentSyncCommittee.equal(syntheticConsensusState().CurrentSyncCommittee))
}

// An update attested in Gloas (gindices 735 and 2946, execution block hash at
// 2856) and signed under the Gloas domain (signature slot 145, domain at 144),
// whose finalized header is still Fulu, with its payload header at gindex 25.
func TestSyntheticGloasTransition(t *testing.T) {
	c := syntheticClient(t)
	hdr := syntheticTransition()
	urequire.True(t, c.ClientState.isGloas(hdr.ConsensusUpdate.AttestedHeader.Beacon.Slot))
	urequire.False(t, c.ClientState.isGloas(hdr.ConsensusUpdate.FinalizedHeader.Beacon.Slot))
	applySynthetic(t, hdr)
}

// The same transition with the finalized Fulu header in Gloas' block-hash
// form (gindex 812, an 11-node normalized branch): the client takes the
// execution data from the full RLP execution header, which must hash to it.
func TestSyntheticHashFormFinalized(t *testing.T) {
	hdr := syntheticHashFormTransition()
	urequire.True(t, hdr.ConsensusUpdate.FinalizedHeader.hashForm())
	urequire.Equal(t, 11, len(hdr.ConsensusUpdate.FinalizedHeader.ExecutionBranch))
	applySynthetic(t, hdr)

	bad := syntheticHashFormTransition()
	bad.ConsensusUpdate.FinalizedExecutionHeader = flip(bad.ConsensusUpdate.FinalizedExecutionHeader, 100)
	urequire.ErrorContains(t, syntheticClient(t).VerifyClientMessage(bad), "finalized execution header does not match the execution block hash")
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
