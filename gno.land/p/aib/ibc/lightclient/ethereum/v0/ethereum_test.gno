package ethereum

import (
	"testing"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestFixtureERC20(t *testing.T)       { runFixture(t, fixtureErc20()) }
func TestFixtureNative(t *testing.T)      { runFixture(t, fixtureNative()) }
func TestFixtureMultiPeriod(t *testing.T) { runFixture(t, fixtureMultiperiod()) }
func TestFixtureTimeout(t *testing.T)     { runFixture(t, fixtureTimeout()) }

// firstUpdate returns a client initialized from f and f's first update, with
// the block time set so that the update is acceptable.
func firstUpdate(t *testing.T, f fixture) (*EthLightClient, *Header) {
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	for _, s := range f.steps {
		if s.update != nil {
			u := s.update.ConsensusUpdate
			setNow(f.clientState.GenesisTime + (u.SignatureSlot-f.clientState.GenesisSlot+1)*f.clientState.SecondsPerSlot)
			urequire.NoError(t, c.VerifyClientMessage(s.update))
			return c, s.update
		}
	}
	t.Fatal("no update")
	return nil, nil
}

func flip(b []byte, i int) []byte {
	out := append([]byte{}, b...)
	out[i] ^= 1
	return out
}

func TestUpdateRejectsTampering(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(h *Header)
		err    string
	}{
		{"signature", func(h *Header) {
			h.ConsensusUpdate.SyncAggregate.SyncCommitteeSignature = flip(h.ConsensusUpdate.SyncAggregate.SyncCommitteeSignature, 50)
		}, "invalid sync committee signature"},
		{"attested header", func(h *Header) {
			h.ConsensusUpdate.AttestedHeader.Beacon.ProposerIndex++
		}, "invalid sync committee signature"},
		{"finalized execution state root", func(h *Header) {
			h.ConsensusUpdate.FinalizedHeader.Execution.StateRoot = flip(h.ConsensusUpdate.FinalizedHeader.Execution.StateRoot, 0)
		}, "invalid execution branch"},
		{"finality branch", func(h *Header) {
			h.ConsensusUpdate.FinalityBranch[0] = flip(h.ConsensusUpdate.FinalityBranch[0], 0)
		}, "invalid finality branch"},
		{"active committee", func(h *Header) {
			h.ActiveSyncCommittee.Pubkeys[0] = h.ActiveSyncCommittee.Pubkeys[1]
		}, "active sync committee does not match"},
		{"participation", func(h *Header) {
			bits := h.ConsensusUpdate.SyncAggregate.SyncCommitteeBits
			for i := range bits {
				bits[i] = 0
			}
			bits[0] = 1
		}, "insufficient sync committee participants"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, hdr := firstUpdate(t, fixtureErc20())
			tc.mutate(hdr)
			urequire.ErrorContains(t, c.VerifyClientMessage(hdr), tc.err)
		})
	}
}

func TestUpdateRejectsFutureSignature(t *testing.T) {
	f := fixtureErc20()
	c, hdr := firstUpdate(t, f)
	sigSlot := hdr.ConsensusUpdate.SignatureSlot
	setNow(f.clientState.GenesisTime + (sigSlot-f.clientState.GenesisSlot-1)*f.clientState.SecondsPerSlot)
	urequire.ErrorContains(t, c.VerifyClientMessage(hdr), "after the current slot")
}

func TestProofRejectsTampering(t *testing.T) {
	f := fixtureErc20()
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	var p *fixtureProof
	for _, s := range f.steps {
		if s.update != nil {
			u := s.update.ConsensusUpdate
			setNow(f.clientState.GenesisTime + (u.SignatureSlot-f.clientState.GenesisSlot+1)*f.clientState.SecondsPerSlot)
			urequire.NoError(t, c.VerifyClientMessage(s.update))
			c.UpdateState(s.update)
		}
		if s.proof != nil && s.proof.ack == nil && !s.proof.absent {
			p = s.proof
			break
		}
	}
	urequire.True(t, p != nil, "no packet proof in fixture")
	key := host.PacketCommitmentKey(p.packet.SourceClient, p.packet.Sequence)
	value := types.CommitPacket(p.packet)
	urequire.NoError(t, c.VerifyMembershipProof(p.height, p.proof, ethPath(key), value))

	urequire.ErrorContains(t, c.VerifyMembershipProof(p.height, p.proof, ethPath(key), flip(value, 0)),
		"differs from the expected value")
	urequire.Error(t, c.VerifyNonMembershipProof(p.height, p.proof, ethPath(key)))

	otherKey := host.PacketCommitmentKey(p.packet.SourceClient, p.packet.Sequence+1)
	urequire.Error(t, c.VerifyMembershipProof(p.height, p.proof, ethPath(otherKey), value))

	bad := MembershipProof{AccountProof: p.proof.AccountProof, StorageProof: append([][]byte{}, p.proof.StorageProof...)}
	last := len(bad.StorageProof) - 1
	bad.StorageProof[last] = flip(bad.StorageProof[last], len(bad.StorageProof[last])-1)
	urequire.Error(t, c.VerifyMembershipProof(p.height, bad, ethPath(key), value))

	urequire.ErrorContains(t, c.VerifyMembership(p.height, nil, ethPath(key), value), "extproof")
}

// An update that does not advance finality is only accepted when it reveals
// a next sync committee the trusted state does not know yet.
func TestUpdateWithoutProgressRejected(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	c.UpdateState(hdr)
	finalized := hdr.ConsensusUpdate.FinalizedHeader.Beacon.Slot
	cons, ok := c.GetConsensusState(heightAtSlot(finalized))
	urequire.True(t, ok)
	urequire.True(t, cons.NextSyncCommittee != nil, "fixture state should know the next committee")

	// The update rolled the client into the period its committee signs in,
	// where that committee is now the current one.
	again := *hdr
	again.TrustedSlot = finalized
	again.ActiveIsNext = false
	urequire.ErrorContains(t, c.VerifyClientMessage(&again), "is not after trusted slot")
}
