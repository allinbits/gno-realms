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
		{"missing non-signer", func(h *Header) {
			bits := h.ConsensusUpdate.SyncAggregate.SyncCommitteeBits
			bits[0] &^= 1 // member 0 did not sign, but the update does not say who it is
			h.ConsensusUpdate.NonSigners = nil
		}, "non-signer 0 is missing"},
		{"forged non-signer", func(h *Header) {
			bits := h.ConsensusUpdate.SyncAggregate.SyncCommitteeBits
			bits[0] &^= 1
			h.ConsensusUpdate.NonSigners = []NonSigner{{Pubkey: make([]byte, 48), Branch: [][]byte{make([]byte, 32)}}}
		}, "invalid branch for non-signer 0"},
		{"extra non-signer", func(h *Header) {
			h.ConsensusUpdate.NonSigners = append(h.ConsensusUpdate.NonSigners, NonSigner{Pubkey: make([]byte, 48)})
		}, "more non-signers than unset participation bits"},
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

// An update anchored at a stored state other than the latest is refused, even
// a valid one: once the client has moved on, an older committee cannot add
// state roots behind the latest slot.
func TestUpdateFromOlderTrustedStateRejected(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	c.UpdateState(hdr)
	urequire.True(t, c.ClientState.LatestSlot > hdr.TrustedSlot, "the update should have advanced the client")
	urequire.ErrorContains(t, c.VerifyClientMessage(hdr), "updates must build on the latest trusted slot")
}

// SSZ hashes fixed-size fields side by side, so moving the state root's bytes
// into the receipts root keeps the execution header's root. Fixed sizes are
// checked first, so such a header is refused instead of storing an empty root.
func TestUpdateRejectsShiftedSSZFields(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	shifted := *hdr
	u := shifted.ConsensusUpdate
	ex := u.FinalizedHeader.Execution
	urequire.True(t, ex.StateRoot != nil, "the fixture should be pre-Gloas")
	before := ex.HashTreeRoot()
	ex.ReceiptsRoot = append(append([]byte{}, ex.StateRoot...), ex.ReceiptsRoot...)
	ex.StateRoot = []byte{}
	urequire.True(t, bytesEqual(before, ex.HashTreeRoot()), "the shift should keep the SSZ root")
	u.FinalizedHeader.Execution = ex
	shifted.ConsensusUpdate = u
	urequire.ErrorContains(t, c.VerifyClientMessage(&shifted), "state root must be 32 bytes")

	short := *hdr
	su := short.ConsensusUpdate
	branch := append([][]byte{}, su.FinalityBranch...)
	branch[0] = branch[0][:31]
	su.FinalityBranch = branch
	short.ConsensusUpdate = su
	urequire.ErrorContains(t, c.VerifyClientMessage(&short), "finality branch")
}

// The client keeps copies of every byte slice it is given: changing the
// caller's input after Initialize or a verified update changes nothing trusted.
func TestStateDoesNotAliasInput(t *testing.T) {
	f := fixtureErc20()
	cons := f.consensusState
	cons.StateRoot = append([]byte{}, cons.StateRoot...)
	cons.CurrentSyncCommittee.PubkeysHash = append([]byte{}, cons.CurrentSyncCommittee.PubkeysHash...)
	cs := f.clientState
	cs.IBCContractAddress = append([]byte{}, cs.IBCContractAddress...)
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	cons.StateRoot[0] ^= 1
	cons.CurrentSyncCommittee.PubkeysHash[0] ^= 1
	cs.IBCContractAddress[0] ^= 1
	stored, ok := c.GetConsensusState(heightAtSlot(cons.Slot))
	urequire.True(t, ok)
	urequire.False(t, bytesEqual(stored.StateRoot, cons.StateRoot), "stored state root aliases the input")
	urequire.False(t, bytesEqual(stored.CurrentSyncCommittee.PubkeysHash, cons.CurrentSyncCommittee.PubkeysHash), "stored committee aliases the input")
	urequire.False(t, bytesEqual(c.ClientState.IBCContractAddress, cs.IBCContractAddress), "client state aliases the input")

	c2, hdr := firstUpdate(t, f)
	c2.UpdateState(hdr)
	finalized := hdr.ConsensusUpdate.FinalizedHeader.Beacon.Slot
	before, ok := c2.GetConsensusState(heightAtSlot(finalized))
	urequire.True(t, ok)
	root := append([]byte{}, before.StateRoot...)
	var next []byte
	if before.NextSyncCommittee != nil {
		next = append([]byte{}, before.NextSyncCommittee.AggregatePubkey...)
	}
	u := &hdr.ConsensusUpdate
	if u.FinalizedHeader.Execution.StateRoot != nil {
		u.FinalizedHeader.Execution.StateRoot[0] ^= 1
	}
	for i := range u.FinalizedExecutionHeader {
		u.FinalizedExecutionHeader[i] ^= 1
	}
	if u.NextSyncCommittee != nil {
		u.NextSyncCommittee.AggregatePubkey[0] ^= 1
	}
	after, _ := c2.GetConsensusState(heightAtSlot(finalized))
	urequire.True(t, bytesEqual(root, after.StateRoot), "trusted state root changed with the update's input")
	if next != nil {
		urequire.True(t, bytesEqual(next, after.NextSyncCommittee.AggregatePubkey), "trusted next committee changed with the update's input")
	}
}

// The client expires exactly TrustingPeriods sync committee periods' worth of
// slots after its latest trusted slot, wherever that slot falls in its period:
// it reports Expired and refuses updates until recovered.
func TestClientExpires(t *testing.T) {
	f := fixtureErc20()
	c, hdr := firstUpdate(t, f)
	urequire.Equal(t, "Active", string(c.Status()))
	cs := c.ClientState
	window := TrustingPeriods * cs.EpochsPerSyncCommitteePeriod * cs.SlotsPerEpoch
	timeAt := func(slot uint64) uint64 { return cs.GenesisTime + (slot-cs.GenesisSlot)*cs.SecondsPerSlot }

	setNow(timeAt(cs.LatestSlot + window))
	urequire.Equal(t, "Active", string(c.Status()), "still active at the last slot of the window")
	setNow(timeAt(cs.LatestSlot + window + 1))
	urequire.Equal(t, "Expired", string(c.Status()), "expired one slot after the window")
	urequire.ErrorContains(t, c.VerifyClientMessage(hdr), "client expired")
}

// Misbehaviour evidence needs the 2/3 supermajority an update needs, not only
// the configured minimum participation.
func TestMisbehaviourNeedsSupermajority(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	u1 := hdr.ConsensusUpdate
	u2 := hdr.ConsensusUpdate
	u2.FinalizedHeader.Beacon.ProposerIndex++ // a different finalized header at the same slot
	bits := append([]byte{}, u2.SyncAggregate.SyncCommitteeBits...)
	for i := range bits {
		bits[i] = 0
	}
	n := int(u2.SyncAggregate.size()) * 2 / 3 // one short of 2/3 when size is not a multiple of 3
	if int(u2.SyncAggregate.size())*2%3 == 0 {
		n--
	}
	for i := 0; i < n; i++ {
		bits[i/8] |= 1 << uint(i%8)
	}
	u2.SyncAggregate.SyncCommitteeBits = bits
	m := &Misbehaviour{TrustedSlot: hdr.TrustedSlot, ActiveIsNext: hdr.ActiveIsNext, Update1: u1, Update2: u2}
	urequire.ErrorContains(t, c.VerifyClientMessage(m), "not enough sync committee signatures")
}

// Misbehaviour is conflicting finality: two updates attesting different heads
// but finalizing the same header are not evidence, and evidence must build on
// the latest trusted state.
func TestMisbehaviourNeedsConflictingFinality(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	u := hdr.ConsensusUpdate
	sameFinality := &Misbehaviour{TrustedSlot: hdr.TrustedSlot, ActiveIsNext: hdr.ActiveIsNext, Update1: u, Update2: u}
	urequire.ErrorContains(t, c.VerifyClientMessage(sameFinality), "finalize the same beacon header")

	c.UpdateState(hdr)
	stale := &Misbehaviour{TrustedSlot: hdr.TrustedSlot, ActiveIsNext: hdr.ActiveIsNext, Update1: u, Update2: u}
	urequire.ErrorContains(t, c.VerifyClientMessage(stale), "updates must build on the latest trusted slot")
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

// A finality update carries no next sync committee, and relayers submit one
// at every rotation. Crossing into the next period with it must work: the
// client rotates its committees and marks the next one unknown, so an update
// signed by the period after is refused until a later update reveals it.
func TestCrossingWithoutNextCommittee(t *testing.T) {
	f := fixtureMultiperiod()
	var steps []*Header
	for _, s := range f.steps {
		if s.update != nil {
			steps = append(steps, s.update)
		}
	}
	urequire.True(t, len(steps) >= 2, "fixture needs two updates")
	full := steps[0]
	cs := f.clientState
	urequire.True(t, cs.periodAtSlot(full.ConsensusUpdate.FinalizedHeader.Beacon.Slot) > cs.periodAtSlot(full.TrustedSlot), "first update should cross a period")

	fin := *full
	fin.ConsensusUpdate.NextSyncCommittee = nil
	fin.ConsensusUpdate.NextSyncCommitteeBranch = nil
	urequire.NoError(t, fin.ValidateBasic())

	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	u := fin.ConsensusUpdate
	setNow(cs.GenesisTime + (u.SignatureSlot-cs.GenesisSlot+1)*cs.SecondsPerSlot)
	urequire.NoError(t, c.VerifyClientMessage(&fin))
	c.UpdateState(&fin)

	finalized := u.FinalizedHeader.Beacon.Slot
	urequire.Equal(t, finalized, c.LatestHeight().RevisionHeight)
	cons, ok := c.GetConsensusState(heightAtSlot(finalized))
	urequire.True(t, ok)
	urequire.True(t, cons.NextSyncCommittee == nil, "the next committee should be unknown after crossing without it")
	urequire.True(t, bytesEqual(f.consensusState.NextSyncCommittee.PubkeysHash, cons.CurrentSyncCommittee.PubkeysHash), "the old next committee should now be current")

	next := steps[1]
	u = next.ConsensusUpdate
	setNow(cs.GenesisTime + (u.SignatureSlot-cs.GenesisSlot+1)*cs.SecondsPerSlot)
	urequire.Error(t, c.VerifyClientMessage(next), "an update signed by an unknown committee must be refused")
}

// Initialize runs once: a stored client's trusted state is never replaced
// through it (Codex round 17).
func TestInitializeOnce(t *testing.T) {
	f := fixtureNative()
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	before := c.LatestHeight()
	cs, cons := f.clientState, f.consensusState
	cs.LatestSlot, cons.Slot = cs.LatestSlot+1000, cons.Slot+1000
	if c.Initialize(cs, cons) == nil {
		t.Fatalf("initialized twice")
	}
	if c.LatestHeight() != before {
		t.Fatalf("trusted state moved: %v", c.LatestHeight())
	}
}

// A replacement keeps every trusted height without copying it (ADR pr6375
// R16): NewFrom does constant work whatever the retired verifier's history,
// serves each of its consensus states, stores its own apart, and never writes
// to the retired verifier (Codex round 26 #2).
func TestNewFromKeepsHistory(t *testing.T) {
	f := fixtureNative()
	old := NewEthLightClient()
	urequire.NoError(t, old.Initialize(f.clientState, f.consensusState))
	base := f.consensusState
	for i := uint64(1); i <= 250; i++ {
		cons := copyConsensusState(base)
		cons.Slot = base.Slot + i
		cons.StateRoot = []byte{byte(i), 1, 2, 3}
		old.setConsensusState(&cons)
	}
	cs := *old.ClientState
	cs.LatestSlot = base.Slot + 250
	old.ClientState = &cs

	c := NewFrom(old)
	if n := c.ConsensusStateByHeight.Size(); n != 0 {
		t.Fatalf("NewFrom copied %d consensus states", n)
	}
	for i := uint64(0); i <= 250; i++ {
		got, ok := c.GetConsensusState(heightAtSlot(base.Slot + i))
		want, _ := old.GetConsensusState(heightAtSlot(base.Slot + i))
		if !ok || got != want {
			t.Fatalf("height %d not served from the retired verifier", base.Slot+i)
		}
	}
	if c.LatestHeight() != old.LatestHeight() || c.Status() != old.Status() {
		t.Fatalf("head: %v %v", c.LatestHeight(), c.Status())
	}

	// The new verifier's own states, a later one and one at a retired
	// height, never reach the retired verifier.
	later := copyConsensusState(base)
	later.Slot = base.Slot + 300
	c.setConsensusState(&later)
	again := copyConsensusState(base)
	again.Slot = base.Slot + 10
	again.StateRoot = []byte{0xee}
	c.setConsensusState(&again)
	if n := old.ConsensusStateByHeight.Size(); n != 251 {
		t.Fatalf("the retired verifier changed: %d states", n)
	}
	if got, _ := old.GetConsensusState(heightAtSlot(base.Slot + 10)); got.StateRoot[0] != 10 {
		t.Fatalf("the retired verifier's state changed")
	}
	if got, _ := c.GetConsensusState(heightAtSlot(base.Slot + 10)); got.StateRoot[0] != 0xee {
		t.Fatalf("the new verifier's own state is not served first")
	}
	if c.ClientState == old.ClientState {
		t.Fatalf("the client state is shared")
	}
	// A recovery of the new verifier stops trusting every height below the
	// state it copies, retired ones included.
	c.TrustedFromSlot = base.Slot + 300
	if _, ok := c.GetConsensusState(heightAtSlot(base.Slot + 5)); ok {
		t.Fatalf("a height below TrustedFromSlot was served")
	}
}
