package ethereum

import (
	"bytes"
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
		}, "not enough sync committee signatures"},
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
	urequire.True(t, bytes.Equal(before, ex.HashTreeRoot()), "the shift should keep the SSZ root")
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
	cs.GenesisValidatorsRoot = append([]byte{}, cs.GenesisValidatorsRoot...)
	gvr := append([]byte{}, cs.GenesisValidatorsRoot...)
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	cons.StateRoot[0] ^= 1
	cons.CurrentSyncCommittee.PubkeysHash[0] ^= 1
	cs.IBCContractAddress[0] ^= 1
	cs.GenesisValidatorsRoot[0] ^= 1
	urequire.True(t, bytes.Equal(gvr, c.ClientState.GenesisValidatorsRoot), "genesis validators root aliases the input")
	stored, ok := c.GetConsensusState(heightAtSlot(cons.Slot))
	urequire.True(t, ok)
	urequire.False(t, bytes.Equal(stored.StateRoot, cons.StateRoot), "stored state root aliases the input")
	urequire.False(t, bytes.Equal(stored.CurrentSyncCommittee.PubkeysHash, cons.CurrentSyncCommittee.PubkeysHash), "stored committee aliases the input")
	urequire.False(t, bytes.Equal(c.ClientState.IBCContractAddress, cs.IBCContractAddress), "client state aliases the input")

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
	urequire.True(t, bytes.Equal(root, after.StateRoot), "trusted state root changed with the update's input")
	if next != nil {
		urequire.True(t, bytes.Equal(next, after.NextSyncCommittee.AggregatePubkey), "trusted next committee changed with the update's input")
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
	urequire.True(t, bytes.Equal(f.consensusState.NextSyncCommittee.PubkeysHash, cons.CurrentSyncCommittee.PubkeysHash), "the old next committee should now be current")

	next := steps[1]
	u = next.ConsensusUpdate
	setNow(cs.GenesisTime + (u.SignatureSlot-cs.GenesisSlot+1)*cs.SecondsPerSlot)
	urequire.ErrorContains(t, c.VerifyClientMessage(next), "next sync committee is not known")
}

// updates returns the client updates of f, in order.
func updates(f fixture) []*Header {
	var out []*Header
	for _, s := range f.steps {
		if s.update != nil {
			out = append(out, s.update)
		}
	}
	return out
}

// verifyAt verifies hdr on c a slot after its signature slot.
func verifyAt(c *EthLightClient, hdr *Header) error {
	cs := c.ClientState
	setNow(cs.GenesisTime + (hdr.ConsensusUpdate.SignatureSlot-cs.GenesisSlot+1)*cs.SecondsPerSlot)
	return c.VerifyClientMessage(hdr)
}

// The signing committee follows from the signature period: a relayer's
// ActiveIsNext that disagrees with it changes nothing, in either direction.
func TestActiveIsNextIgnored(t *testing.T) {
	f := fixtureNative()
	steps := updates(f)
	cs := f.clientState
	crossing, within := *steps[0], *steps[1]
	urequire.True(t, cs.periodAtSlot(crossing.ConsensusUpdate.SignatureSlot) == cs.periodAtSlot(crossing.TrustedSlot)+1 && crossing.ActiveIsNext,
		"the first update should be signed by the next committee")
	urequire.True(t, cs.periodAtSlot(within.ConsensusUpdate.SignatureSlot) == cs.periodAtSlot(within.TrustedSlot) && !within.ActiveIsNext,
		"the second update should be signed by the current committee")

	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	crossing.ActiveIsNext = false
	urequire.NoError(t, verifyAt(c, &crossing))
	c.UpdateState(&crossing)

	within.ActiveIsNext = true
	urequire.NoError(t, verifyAt(c, &within))
}

// signedFrom returns a client whose latest trusted state is at slot, in the
// period of the ERC20 fixture's first update and signed by its committee,
// with next as its next committee, and that update. Its periods are
// epochsPerPeriod epochs long: the signature does not depend on them.
func signedFrom(t *testing.T, slot, epochsPerPeriod uint64, next *SummarizedSyncCommittee) (*EthLightClient, *Header) {
	f := fixtureErc20()
	hdr := *updates(f)[0]
	hdr.TrustedSlot = slot
	cs := f.clientState
	cs.LatestSlot = slot
	cs.EpochsPerSyncCommitteePeriod = epochsPerPeriod
	cons := ConsensusState{
		Slot:                 slot,
		StateRoot:            f.consensusState.StateRoot,
		Timestamp:            f.consensusState.Timestamp,
		CurrentSyncCommittee: *f.consensusState.NextSyncCommittee, // the committee that signs hdr
		NextSyncCommittee:    next,
	}
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, cons))
	return c, &hdr
}

// An update signed in the stored period whose next committee differs from the
// one the trusted state knows is refused, as validate_light_client_update
// refuses it, whatever ActiveIsNext says.
func TestSamePeriodNextCommitteeMustMatch(t *testing.T) {
	_, hdr := signedFrom(t, 140, 8, nil)
	u := hdr.ConsensusUpdate
	cs := fixtureErc20().clientState
	urequire.True(t, cs.periodAtSlot(140) == cs.periodAtSlot(u.AttestedHeader.Beacon.Slot) &&
		cs.periodAtSlot(140) == cs.periodAtSlot(u.SignatureSlot), "slot 140 should be in the update's period")

	other := cloneSummary(*u.NextSyncCommittee)
	other.PubkeysHash[0] ^= 1
	for _, flag := range []bool{false, true} {
		c, hdr := signedFrom(t, 140, 8, &other)
		hdr.ActiveIsNext = flag
		urequire.ErrorContains(t, verifyAt(c, hdr), "next sync committee does not match")
	}

	// The same update against the committee it carries passes validation; it
	// does not advance finality and the next committee is known, so it is
	// refused only for that.
	same := cloneSummary(*u.NextSyncCommittee)
	c, hdr := signedFrom(t, 140, 8, &same)
	hdr.ActiveIsNext = false
	urequire.ErrorContains(t, verifyAt(c, hdr), "is not after trusted slot")
}

// An update that does not advance finality only reveals a next committee if
// its finalized header is in the attested header's period, as in the spec's
// update_has_finalized_next_sync_committee: before that header, the period's
// next committee is not final.
func TestNextCommitteeOnlyNeedsFinalizedPeriod(t *testing.T) {
	// 8-epoch periods: the finalized (128), trusted (140) and attested (144)
	// slots share a period, and the update records the next committee.
	c, hdr := signedFrom(t, 140, 8, nil)
	urequire.NoError(t, verifyAt(c, hdr))
	c.UpdateState(hdr)
	cons, _ := c.GetConsensusState(heightAtSlot(140))
	urequire.True(t, cons.NextSyncCommittee != nil, "the next committee should be recorded")

	// 17-epoch periods (136 slots): the finalized slot 128 is in the period
	// before the others.
	c, hdr = signedFrom(t, 140, 17, nil)
	cs := c.ClientState
	u := hdr.ConsensusUpdate
	urequire.True(t, cs.periodAtSlot(u.FinalizedHeader.Beacon.Slot)+1 == cs.periodAtSlot(u.AttestedHeader.Beacon.Slot) &&
		cs.periodAtSlot(u.AttestedHeader.Beacon.Slot) == cs.periodAtSlot(140), "the finalized header should be one period behind")
	urequire.ErrorContains(t, verifyAt(c, hdr), "is not after trusted slot")
}

// rlpHeader is a minimal RLP execution block header with the given state root,
// block number 1 and timestamp 1.
func rlpHeader(stateRoot []byte) []byte {
	payload := []byte{0x80, 0x80, 0x80, 0xa0}
	payload = append(payload, stateRoot...)
	payload = append(payload, 0x80, 0x80, 0x80, 0x80, 0x01, 0x80, 0x80, 0x01)
	return append([]byte{0xc0 + byte(len(payload))}, payload...)
}

// From Gloas on, a header finalizing a stored slot is misbehaviour only if its
// execution header is the one the beacon header commits to: verifyHeader
// does not check that hash for an update that does not advance finality.
func TestMisbehaviourChecksExecutionHash(t *testing.T) {
	f := fixtureErc20()
	cs := f.clientState
	cs.ForkParameters.Gloas = Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 1}
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(cs, f.consensusState))
	urequire.True(t, c.ClientState.isGloas(cs.LatestSlot))

	root := flip(f.consensusState.StateRoot, 0)
	hdr := &Header{TrustedSlot: cs.LatestSlot}
	hdr.ConsensusUpdate.FinalizedHeader.Beacon.Slot = cs.LatestSlot
	hdr.ConsensusUpdate.FinalizedExecutionHeader = rlpHeader(root)
	hdr.ConsensusUpdate.FinalizedHeader.ExecutionBlockHash = make([]byte, hashSize)
	urequire.False(t, c.CheckForMisbehaviour(hdr), "an execution header off its committed hash is not evidence")

	hdr.ConsensusUpdate.FinalizedHeader.ExecutionBlockHash = keccak(rlpHeader(root))
	urequire.True(t, c.CheckForMisbehaviour(hdr), "a committed execution header with another state root is evidence")
}

// The fork schedule decides the signing domain, the Merkle layout and the
// supported range, so ValidateBasic refuses one no update could pass.
func TestClientStateValidatesForks(t *testing.T) {
	urequire.NoError(t, fixtureErc20().clientState.ValidateBasic())
	cases := []struct {
		name   string
		mutate func(cs *ClientState)
		err    string
	}{
		{"zero gloas after a later fork", func(cs *ClientState) { cs.ForkParameters.Gloas = Fork{} }, "gloas fork epoch 0 precedes the previous fork's 1"},
		// Every fork at epoch 0, as on a devnet starting at Fulu: only the
		// missing version shows the zero Gloas.
		{"zero gloas", func(cs *ClientState) {
			cs.ForkParameters.Fulu.Epoch = 0
			cs.ForkParameters.Gloas = Fork{}
		}, "gloas fork is scheduled at epoch 0 without a version"},
		{"out of order", func(cs *ClientState) { cs.ForkParameters.Deneb.Epoch = 5 }, "electra fork epoch 0 precedes the previous fork's 5"},
		{"electra unscheduled", func(cs *ClientState) {
			cs.ForkParameters.Electra.Epoch = FarFutureEpoch
			cs.ForkParameters.Fulu.Epoch = FarFutureEpoch
		}, "electra fork must be scheduled"},
		{"fork genesis slot differs", func(cs *ClientState) { cs.ForkParameters.GenesisSlot = 5 }, "fork parameters genesis slot 5 differs from genesis slot 0"},
		{"latest slot before electra", func(cs *ClientState) {
			cs.ForkParameters.Electra.Epoch = 20
			cs.ForkParameters.Fulu.Epoch = 20
		}, "is before Electra"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cs := fixtureErc20().clientState
			tc.mutate(&cs)
			urequire.ErrorContains(t, cs.ValidateBasic(), tc.err)
		})
	}
}

// applied returns a client initialized from f that applied its first n
// updates, each verified a slot after its signature slot.
func applied(t *testing.T, f fixture, n int) *EthLightClient {
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	for _, hdr := range updates(f)[:n] {
		urequire.NoError(t, verifyAt(c, hdr))
		c.UpdateState(hdr)
	}
	return c
}

// withForks returns a copy of c's client state with its fork schedule mutated.
func withForks(c *EthLightClient, mutate func(p *ForkParameters)) *ClientState {
	cs := *c.ClientState
	mutate(&cs.ForkParameters)
	return &cs
}

// A recovery adopts the substitute's fork schedule, whatever the subject's
// was, as long as it is valid: no fork comparison binds the two (see
// RecoverClient). The subject applied the ERC20 fixture's first update; the
// substitute two.
func TestRecoverClientForks(t *testing.T) {
	gloas := Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 20}
	cases := []struct {
		name   string
		mutate func(p *ForkParameters)
		err    string
	}{
		{"gloas scheduled", func(p *ForkParameters) { p.Gloas = gloas }, ""},
		{"gloas scheduled where the subject verified updates", func(p *ForkParameters) { p.Gloas = Fork{Version: gloas.Version, Epoch: 17} }, ""},
		{"active fork rewritten", func(p *ForkParameters) { p.Fulu.Version[0]++ }, ""},
		{"fork without a version", func(p *ForkParameters) { p.Gloas = Fork{Epoch: 30} }, "without a version"},
		{"forks out of order", func(p *ForkParameters) { p.Deneb.Epoch = 5 }, "precedes the previous fork's"},
		{"fork genesis slot", func(p *ForkParameters) { p.GenesisSlot++ }, "fork parameters genesis slot 1 differs from genesis slot 0"},
		{"genesis fork version", func(p *ForkParameters) { p.GenesisForkVersion[0]++ }, "different chain or router"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := fixtureErc20()
			subject := applied(t, f, 1)
			before := *subject.ClientState
			sub := applied(t, f, 2)
			sub.ClientState = withForks(sub, tc.mutate)

			err := subject.RecoverClient(sub)
			if tc.err != "" {
				urequire.ErrorContains(t, err, tc.err)
				urequire.True(t, subject.ClientState.ForkParameters == before.ForkParameters, "a refused recovery changes nothing")
				urequire.Equal(t, before.LatestSlot, subject.ClientState.LatestSlot)
				return
			}
			urequire.NoError(t, err)
			urequire.Equal(t, sub.ClientState.LatestSlot, subject.ClientState.LatestSlot)
			urequire.True(t, subject.ClientState.ForkParameters == sub.ClientState.ForkParameters, "the subject takes the substitute's schedule")
		})
	}
}

// A client created with a wrong schedule for a fork already active, which
// accepts no update, is recovered in place from a substitute with the right
// one, and then verifies updates.
func TestRecoverNeverUpdatedClient(t *testing.T) {
	f := fixtureErc20()
	cs := f.clientState
	cs.ForkParameters.Fulu.Version[0]++ // active since epoch 1, before the bootstrap at epoch 9
	subject := NewEthLightClient()
	urequire.NoError(t, subject.Initialize(cs, f.consensusState))
	urequire.ErrorContains(t, verifyAt(subject, updates(f)[0]), "invalid sync committee signature")

	urequire.NoError(t, subject.RecoverClient(applied(t, f, 1)))
	urequire.True(t, subject.ClientState.ForkParameters == f.clientState.ForkParameters)
	urequire.NoError(t, verifyAt(subject, updates(f)[1]))
}

// A recovered subject verifies later updates under the schedule it adopted.
func TestRecoverThenUpdate(t *testing.T) {
	f := fixtureErc20()
	steps := updates(f)
	subject := applied(t, f, 1)
	sub := applied(t, f, 2)
	sub.ClientState = withForks(sub, func(p *ForkParameters) {
		p.Gloas = Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 100}
	})
	urequire.NoError(t, subject.RecoverClient(sub))
	urequire.NoError(t, verifyAt(subject, steps[2]))
	subject.UpdateState(steps[2])
	urequire.Equal(t, steps[2].ConsensusUpdate.FinalizedHeader.Beacon.Slot, subject.ClientState.LatestSlot)
	urequire.Equal(t, uint64(100), subject.ClientState.ForkParameters.Gloas.Epoch)
}

// A next-committee-only update records a copy of the committee it reveals:
// changing the caller's input afterwards changes nothing trusted.
func TestNextCommitteeOnlyDoesNotAliasInput(t *testing.T) {
	c, hdr := signedFrom(t, 140, 8, nil)
	urequire.NoError(t, verifyAt(c, hdr))
	u := hdr.ConsensusUpdate
	next := cloneSummary(*u.NextSyncCommittee)
	u.NextSyncCommittee = &next
	hdr.ConsensusUpdate = u
	c.UpdateState(hdr)
	want := append([]byte{}, next.AggregatePubkey...)
	next.AggregatePubkey[0] ^= 1
	next.PubkeysHash[0] ^= 1
	cons, _ := c.GetConsensusState(heightAtSlot(140))
	urequire.True(t, bytes.Equal(want, cons.NextSyncCommittee.AggregatePubkey), "the recorded next committee aliases the update")
}

// A recovery unfreezes the subject and takes the substitute's latest slot,
// block number, minimum participation and schedule, and a deep copy of its
// latest consensus state.
func TestRecoverClientWrites(t *testing.T) {
	f := fixtureErc20()
	subject := applied(t, f, 1)
	subject.UpdateStateOnMisbehaviour(nil)
	urequire.Equal(t, "Frozen", string(subject.Status()))
	sub := applied(t, f, 2)
	cs := *sub.ClientState
	cs.MinSyncCommitteeParticipants = 20
	cs.ForkParameters.Gloas = Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 100}
	sub.ClientState = &cs

	urequire.NoError(t, subject.RecoverClient(sub))
	got := subject.ClientState
	urequire.Equal(t, "Active", string(subject.Status()))
	urequire.False(t, got.IsFrozen)
	urequire.Equal(t, cs.LatestSlot, got.LatestSlot)
	urequire.Equal(t, cs.LatestExecutionBlockNumber, got.LatestExecutionBlockNumber)
	urequire.Equal(t, uint64(20), got.MinSyncCommitteeParticipants)
	urequire.True(t, got.ForkParameters == cs.ForkParameters, "the substitute's schedule")

	mine, _ := subject.GetConsensusState(heightAtSlot(cs.LatestSlot))
	theirs, _ := sub.GetConsensusState(heightAtSlot(cs.LatestSlot))
	urequire.True(t, mine != theirs, "a copy, not the substitute's state")
	root := append([]byte{}, mine.StateRoot...)
	agg := append([]byte{}, mine.CurrentSyncCommittee.AggregatePubkey...)
	theirs.StateRoot[0] ^= 1
	theirs.CurrentSyncCommittee.AggregatePubkey[0] ^= 1
	if theirs.NextSyncCommittee != nil {
		theirs.NextSyncCommittee.PubkeysHash[0] ^= 1
	}
	urequire.True(t, bytes.Equal(root, mine.StateRoot), "the copied root aliases the substitute's")
	urequire.True(t, bytes.Equal(agg, mine.CurrentSyncCommittee.AggregatePubkey), "the copied committee aliases the substitute's")
}

// The substitute must be ahead of the subject and track the same chain and
// router.
func TestRecoverClientRefusals(t *testing.T) {
	f := fixtureErc20()
	subject := applied(t, f, 2)
	behind := applied(t, f, 1)
	urequire.ErrorContains(t, subject.RecoverClient(behind), "substitute must be ahead of the subject")
	urequire.ErrorContains(t, subject.RecoverClient(applied(t, f, 2)), "substitute must be ahead of the subject")

	for _, mutate := range []func(cs *ClientState){
		func(cs *ClientState) { cs.ChainID++ },
		func(cs *ClientState) { cs.IBCContractAddress = flip(cs.IBCContractAddress, 0) },
		func(cs *ClientState) { cs.IBCCommitmentSlot = flip(cs.IBCCommitmentSlot, 0) },
		func(cs *ClientState) { cs.GenesisValidatorsRoot = flip(cs.GenesisValidatorsRoot, 0) },
		func(cs *ClientState) { cs.SlotsPerEpoch++ },
		func(cs *ClientState) { cs.SyncCommitteeSize *= 2 },
		func(cs *ClientState) { cs.GenesisTime++ },
		func(cs *ClientState) { cs.GenesisSlot++ },
		func(cs *ClientState) { cs.SecondsPerSlot++ },
		func(cs *ClientState) { cs.EpochsPerSyncCommitteePeriod++ },
		func(cs *ClientState) { cs.ForkParameters.GenesisForkVersion[0]++ },
	} {
		sub := applied(t, f, 3)
		cs := *sub.ClientState
		mutate(&cs)
		sub.ClientState = &cs
		urequire.ErrorContains(t, subject.RecoverClient(sub), "different chain or router")
	}
}
