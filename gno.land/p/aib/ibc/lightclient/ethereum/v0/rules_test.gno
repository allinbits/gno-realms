package ethereum

import (
	"testing"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/urequire/v0"
)

// erc20First is a client initialized from the ERC20 fixture, its client state
// changed by mutate, and a copy of the fixture's first update.
func erc20First(t *testing.T, mutate func(cs *ClientState)) (*EthLightClient, *Header) {
	f := fixtureErc20()
	cs := f.clientState
	if mutate != nil {
		mutate(&cs)
	}
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, f.consensusState))
	hdr := *updates(f)[0]
	return c, &hdr
}

// clearBits clears participation bits from the top until n members signed.
func clearBits(u *LightClientUpdate, n uint64) {
	bits := append([]byte{}, u.SyncAggregate.SyncCommitteeBits...)
	for i := len(bits)*8 - 1; i >= 0 && u.SyncAggregate.participants() > n; i-- {
		bits[i/8] &^= 1 << uint(i%8)
		u.SyncAggregate.SyncCommitteeBits = bits
	}
}

// Each rule of validate_light_client_update and of the header supermajority
// refuses an update otherwise valid.
func TestUpdateRules(t *testing.T) {
	cases := []struct {
		name   string
		client func(cs *ClientState)
		mutate func(h *Header)
		err    string
	}{
		{"next sync committee branch", nil, func(h *Header) {
			b := append([][]byte{}, h.ConsensusUpdate.NextSyncCommitteeBranch...)
			b[0] = flip(b[0], 0)
			h.ConsensusUpdate.NextSyncCommitteeBranch = b
		}, "invalid next sync committee branch"},
		// 21 of 32 signed: above the configured minimum of 11, below 2/3.
		{"below the supermajority", nil, func(h *Header) { clearBits(&h.ConsensusUpdate, 21) }, "not enough sync committee signatures"},
		// 31 of 32 signed: a supermajority, below a minimum of 32.
		{"below the minimum", func(cs *ClientState) { cs.MinSyncCommitteeParticipants = 32 }, func(h *Header) {
			clearBits(&h.ConsensusUpdate, 31)
		}, "insufficient sync committee participants: 31"},
		{"signature slot not after the attested slot", nil, func(h *Header) {
			h.ConsensusUpdate.SignatureSlot = h.ConsensusUpdate.AttestedHeader.Beacon.Slot
		}, "slots must satisfy signature > attested >= finalized"},
		{"finalized slot at genesis", func(cs *ClientState) { cs.GenesisSlot = 128 }, nil, "finalized slot is the genesis slot"},
		{"bit vector longer than the committee", nil, func(h *Header) {
			h.ConsensusUpdate.SyncAggregate.SyncCommitteeBits = append(append([]byte{}, h.ConsensusUpdate.SyncAggregate.SyncCommitteeBits...), 0)
		}, "sync committee bits cover 40 members, committee has 32"},
		{"finalized header in both forms", nil, func(h *Header) {
			h.ConsensusUpdate.FinalizedHeader.ExecutionBlockHash = h.ConsensusUpdate.FinalizedHeader.Execution.BlockHash
		}, "carries both an execution payload header and an execution block hash"},
		{"attested header in neither form", nil, func(h *Header) {
			h.ConsensusUpdate.AttestedHeader.Execution = ExecutionPayloadHeader{}
		}, "execution header parent hash must be 32 bytes"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, hdr := erc20First(t, tc.client)
			if tc.mutate != nil {
				tc.mutate(hdr)
			}
			urequire.ErrorContains(t, verifyAt(c, hdr), tc.err)
		})
	}
}

// An update signed two periods after the trusted state is refused: neither
// the current committee nor the next one signs it.
func TestUpdateSignedTwoPeriodsLater(t *testing.T) {
	f := fixtureErc20()
	cs := f.clientState
	cs.LatestSlot = 10 // period 0; the update is signed in period 2
	cons := f.consensusState
	cons.Slot = 10
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	hdr := *updates(f)[0]
	hdr.TrustedSlot = 10
	urequire.ErrorContains(t, verifyAt(c, &hdr), "signature period 2 is not the stored period 0 or the next")
}

// The signing domain comes from the fork at the signature slot minus one. With
// one slot per epoch, a fork activated at the signature slot (145) is not the
// update's: the update still verifies under Fulu, the version at slot 144.
func TestForkVersionAtSignatureSlotMinusOne(t *testing.T) {
	gloasAt := func(epoch uint64) func(cs *ClientState) {
		return func(cs *ClientState) {
			cs.SlotsPerEpoch = 1
			cs.EpochsPerSyncCommitteePeriod = 64 // the same 64-slot periods
			cs.ForkParameters.Fulu.Epoch = 8     // the same slot as before
			cs.ForkParameters.Gloas = Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: epoch}
		}
	}
	c, hdr := erc20First(t, gloasAt(145))
	urequire.Equal(t, uint64(145), hdr.ConsensusUpdate.SignatureSlot)
	urequire.NoError(t, verifyAt(c, hdr))

	// One slot earlier, Gloas covers the attested header (slot 144) too.
	c, hdr = erc20First(t, gloasAt(144))
	urequire.ErrorContains(t, verifyAt(c, hdr), "execution block hash must be 32 bytes")
}

// hashForm converts an Electra or Fulu header to Gloas' hash form, as
// upgrade_lc_header_to_gloas does: the payload's block hash, proven by the
// branch to it in the payload header followed by the payload's branch in the
// body, normalized to Gloas' 11-node execution branch.
func hashForm(h LightClientHeader) LightClientHeader {
	leaves := h.Execution.fieldRoots()
	for len(leaves) < 32 {
		leaves = append(leaves, make([]byte, chunkSize))
	}
	var branch [][]byte
	idx := 12 // block_hash
	for len(leaves) > 1 {
		branch = append(branch, leaves[idx^1])
		next := make([][]byte, len(leaves)/2)
		for i := range next {
			next[i] = hash2(leaves[2*i], leaves[2*i+1])
		}
		leaves, idx = next, idx/2
	}
	branch = append(branch, h.ExecutionBranch...)
	branch = append([][]byte{make([]byte, chunkSize), make([]byte, chunkSize)}, branch...)
	return LightClientHeader{Beacon: h.Beacon, ExecutionBlockHash: append([]byte{}, h.Execution.BlockHash...), ExecutionBranch: branch}
}

// Electra and Fulu headers are accepted in Gloas' hash form too, proven at
// gindex 812, as a Gloas-era beacon API serves them. A finalized header in
// that form takes its execution data from the RLP execution header, which
// must hash to its block hash.
func TestHashFormPreGloasHeaders(t *testing.T) {
	c, hdr := erc20First(t, nil)
	u := &hdr.ConsensusUpdate
	att := hashForm(u.AttestedHeader)
	urequire.Equal(t, 11, len(att.ExecutionBranch))
	urequire.NoError(t, c.validateLightClientHeader(att))
	fin := hashForm(u.FinalizedHeader)
	urequire.NoError(t, c.validateLightClientHeader(fin))

	// The whole update, with its attested header converted.
	u.AttestedHeader = att
	urequire.NoError(t, verifyAt(c, hdr))

	// A finalized header converted needs the RLP execution header whose
	// hash it commits to. The fixture has no RLP header (it lacks the fields
	// the payload header does not carry, such as the requests hash), so only
	// the refusal is tested here; TestSepolia applies the hash form with one.
	u.FinalizedHeader = fin
	u.FinalizedExecutionHeader = rlpHeader(u.FinalizedHeader.Beacon.StateRoot)
	urequire.ErrorContains(t, verifyAt(c, hdr), "finalized execution header does not match the execution block hash")

	// A tampered node, or a nonzero normalization node, fails.
	for _, i := range []int{5, 0} {
		bad := hashForm(updates(fixtureErc20())[0].ConsensusUpdate.AttestedHeader)
		bad.ExecutionBranch[i] = flip(bad.ExecutionBranch[i], 0)
		urequire.ErrorContains(t, c.validateLightClientHeader(bad), "invalid execution branch")
	}
}

// Misbehaviour updates must finalize the same slot.
func TestMisbehaviourNeedsSameFinalizedSlot(t *testing.T) {
	f := fixtureErc20()
	c, hdr := firstUpdate(t, f)
	other := updates(f)[1].ConsensusUpdate
	m := &Misbehaviour{TrustedSlot: hdr.TrustedSlot, Update1: hdr.ConsensusUpdate, Update2: other}
	urequire.ErrorContains(t, c.VerifyClientMessage(m), "misbehaviour updates finalize different slots")
}

// A proof is refused at a nonzero revision.
func TestProofRevisionNumber(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	c.UpdateState(hdr)
	height := types.NewHeight(1, c.ClientState.LatestSlot)
	key := host.PacketCommitmentKey("client-0", 1)
	urequire.ErrorContains(t, c.VerifyNonMembershipProof(height, MembershipProof{}, ethPath(key)), "revision number must be 0")
}

// The clock: no slot before genesis, slots counted from a nonzero genesis
// slot, and no slot that would wrap.
func TestSlotClock(t *testing.T) {
	cs := fixtureErc20().clientState
	cs.GenesisSlot = 1000
	_, ok := cs.slotAtTimestamp(cs.GenesisTime - 1)
	urequire.False(t, ok, "no slot before genesis")
	s, ok := cs.slotAtTimestamp(cs.GenesisTime + 10*cs.SecondsPerSlot + 1)
	urequire.True(t, ok)
	urequire.Equal(t, uint64(1010), s)

	cs.GenesisSlot = maxUint64 - 5
	_, ok = cs.slotAtTimestamp(cs.GenesisTime + 10*cs.SecondsPerSlot)
	urequire.False(t, ok, "a slot past 2^64 is no slot")

	// Before genesis the client is not expired, and refuses updates.
	c, hdr := erc20First(t, nil)
	setNow(c.ClientState.GenesisTime - 1)
	urequire.Equal(t, "Active", string(c.Status()))
	urequire.ErrorContains(t, c.VerifyClientMessage(hdr), "current time precedes the tracked chain's genesis")
}

// Expiry counts elapsed slots by subtraction, with a nonzero genesis slot and
// a latest slot near 2^64, and ValidateBasic refuses parameters whose window
// would wrap.
func TestExpiryArithmetic(t *testing.T) {
	cs := fixtureErc20().clientState
	cs.EpochsPerSyncCommitteePeriod = 1 << 58 // 8 periods of 8 slots: 2^64 slots
	urequire.ErrorContains(t, cs.ValidateBasic(), "overflow the trusting window")
	cs.EpochsPerSyncCommitteePeriod = 1<<58 - 1
	urequire.NoError(t, cs.ValidateBasic())

	f := fixtureErc20()
	cs = f.clientState
	cs.GenesisSlot = maxUint64 - 200
	cs.LatestSlot = maxUint64 - 100
	cons := f.consensusState
	cons.Slot = cs.LatestSlot
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	window := cs.trustWindow()
	// LatestSlot + window wraps: the client must still be Active at its
	// latest slot.
	setNow(cs.GenesisTime + 100*cs.SecondsPerSlot)
	urequire.Equal(t, "Active", string(c.Status()))

	cs = f.clientState
	cs.GenesisSlot = 500
	cs.LatestSlot = 600
	cons.Slot = 600
	c = NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	at := func(slot uint64) uint64 { return cs.GenesisTime + (slot-cs.GenesisSlot)*cs.SecondsPerSlot }
	setNow(at(600 + window))
	urequire.Equal(t, "Active", string(c.Status()))
	setNow(at(600 + window + 1))
	urequire.Equal(t, "Expired", string(c.Status()))
}
