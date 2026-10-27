package ethereum

import (
	"bytes"
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
	// Past 2^64 the current slot overflows; the latest slot's age does not:
	// 512 slots old it is still Active, 513 it is Expired.
	setNow(cs.GenesisTime + (100+window)*cs.SecondsPerSlot)
	_, ok := cs.slotAtTimestamp(now())
	urequire.False(t, ok, "the current slot is past 2^64")
	urequire.Equal(t, "Active", string(c.Status()))
	setNow(cs.GenesisTime + (100+window+1)*cs.SecondsPerSlot)
	urequire.Equal(t, "Expired", string(c.Status()))

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

// Malformed update shapes are refused by the size checks, before any hashing
// or signature verification: each error is the size check's own.
func TestUpdateShapes(t *testing.T) {
	short := func(b []byte) []byte { return append([]byte{}, b[:len(b)-1]...) }
	cases := []struct {
		name   string
		mutate func(u *LightClientUpdate)
		err    string
	}{
		{"next committee without its branch", func(u *LightClientUpdate) { u.NextSyncCommitteeBranch = nil }, "next sync committee and its branch must be set together"},
		{"branch without the next committee", func(u *LightClientUpdate) { u.NextSyncCommittee = nil }, "next sync committee and its branch must be set together"},
		{"short pubkeys hash", func(u *LightClientUpdate) {
			s := cloneSummary(*u.NextSyncCommittee)
			s.PubkeysHash = short(s.PubkeysHash)
			u.NextSyncCommittee = &s
		}, "next sync committee: pubkeys hash must be 32 bytes"},
		{"short aggregate pubkey", func(u *LightClientUpdate) {
			s := cloneSummary(*u.NextSyncCommittee)
			s.AggregatePubkey = short(s.AggregatePubkey)
			u.NextSyncCommittee = &s
		}, "next sync committee: aggregate pubkey must be 48 bytes"},
		{"95-byte signature", func(u *LightClientUpdate) {
			u.SyncAggregate.SyncCommitteeSignature = short(u.SyncAggregate.SyncCommitteeSignature)
		}, "sync committee signature must be 96 bytes"},
		{"47-byte non-signer key", func(u *LightClientUpdate) {
			u.NonSigners = []NonSigner{{Pubkey: make([]byte, 47)}}
		}, "non-signer 0: pubkey is not 48 bytes"},
		{"short non-signer branch node", func(u *LightClientUpdate) {
			u.NonSigners = []NonSigner{{Pubkey: make([]byte, 48), Branch: [][]byte{make([]byte, 31)}}}
		}, "non-signer 0 branch: node 0 is 31 bytes, not 32"},
		{"short finality branch node", func(u *LightClientUpdate) {
			b := append([][]byte{}, u.FinalityBranch...)
			b[2] = short(b[2])
			u.FinalityBranch = b
		}, "finality branch: node 2 is 31 bytes, not 32"},
		{"short next committee branch node", func(u *LightClientUpdate) {
			b := append([][]byte{}, u.NextSyncCommitteeBranch...)
			b[1] = short(b[1])
			u.NextSyncCommitteeBranch = b
		}, "next sync committee branch: node 1 is 31 bytes, not 32"},
		{"short execution branch node", func(u *LightClientUpdate) {
			b := append([][]byte{}, u.AttestedHeader.ExecutionBranch...)
			b[0] = short(b[0])
			u.AttestedHeader.ExecutionBranch = b
		}, "attested header: execution branch: node 0 is 31 bytes, not 32"},
		{"short beacon parent root", func(u *LightClientUpdate) {
			u.AttestedHeader.Beacon.ParentRoot = short(u.AttestedHeader.Beacon.ParentRoot)
		}, "attested header: beacon header roots must be 32 bytes"},
		{"long beacon body root", func(u *LightClientUpdate) {
			u.FinalizedHeader.Beacon.BodyRoot = append(append([]byte{}, u.FinalizedHeader.Beacon.BodyRoot...), 0)
		}, "finalized header: beacon header roots must be 32 bytes"},
		{"short fee recipient", func(u *LightClientUpdate) {
			u.AttestedHeader.Execution.FeeRecipient = short(u.AttestedHeader.Execution.FeeRecipient)
		}, "execution header fee recipient must be 20 bytes, got 19"},
		{"short logs bloom", func(u *LightClientUpdate) {
			u.FinalizedHeader.Execution.LogsBloom = short(u.FinalizedHeader.Execution.LogsBloom)
		}, "execution header logs bloom must be 256 bytes, got 255"},
		{"long extra data", func(u *LightClientUpdate) {
			u.AttestedHeader.Execution.ExtraData = make([]byte, 33)
		}, "execution header extra data exceeds 32 bytes"},
		{"long base fee", func(u *LightClientUpdate) {
			u.AttestedHeader.Execution.BaseFeePerGas = make([]byte, 33)
		}, "execution header base fee exceeds 32 bytes"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, hdr := erc20First(t, nil)
			tc.mutate(&hdr.ConsensusUpdate)
			urequire.ErrorContains(t, verifyAt(c, hdr), tc.err)
		})
	}
}

// An update that neither advances past the trusted slot nor reveals an
// unknown next committee is irrelevant. The client trusts slot 150 in the
// update's period, knowing its next committee; the update attests 144.
func TestIrrelevantUpdate(t *testing.T) {
	next := cloneSummary(*updates(fixtureErc20())[0].ConsensusUpdate.NextSyncCommittee)
	c, hdr := signedFrom(t, 150, 8, &next)
	urequire.ErrorContains(t, verifyAt(c, hdr), "irrelevant update")
}

// The attested header must not precede the finalized one.
func TestAttestedNotBeforeFinalized(t *testing.T) {
	c, hdr := erc20First(t, nil)
	u := &hdr.ConsensusUpdate
	u.SignatureSlot = 151
	u.FinalizedHeader.Beacon.Slot = 150 // after the attested slot 144
	urequire.ErrorContains(t, verifyAt(c, hdr), "slots must satisfy signature > attested >= finalized")
}

// A finalized header in the hash form gives the execution data of its RLP
// header, whatever its slot: here an Electra-era (pre-Gloas) slot.
func TestHashFormFinalizedExecution(t *testing.T) {
	c, hdr := erc20First(t, nil)
	urequire.False(t, c.ClientState.isGloas(hdr.ConsensusUpdate.FinalizedHeader.Beacon.Slot))
	root := keccak([]byte("execution state root"))
	rlp := rlpHeader(root)
	u := hdr.ConsensusUpdate
	u.FinalizedHeader = LightClientHeader{Beacon: u.FinalizedHeader.Beacon, ExecutionBlockHash: keccak(rlp)}
	u.FinalizedExecutionHeader = rlp
	urequire.NoError(t, c.verifyFinalizedExecution(u))
	exec, err := c.finalizedExecution(u)
	urequire.NoError(t, err)
	urequire.True(t, bytes.Equal(root, exec.stateRoot), "the RLP header's state root")
	urequire.Equal(t, uint64(1), exec.timestamp)
	urequire.Equal(t, uint64(1), exec.blockNumber)
}

// An update stores its finalized execution payload's timestamp and block
// number.
func TestUpdateStoresExecutionMetadata(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	c.UpdateState(hdr)
	ex := hdr.ConsensusUpdate.FinalizedHeader.Execution
	slot := hdr.ConsensusUpdate.FinalizedHeader.Beacon.Slot
	ts, err := c.TimestampAtHeight(heightAtSlot(slot))
	urequire.NoError(t, err)
	urequire.Equal(t, ex.Timestamp, ts)
	urequire.Equal(t, ex.BlockNumber, c.ClientState.LatestExecutionBlockNumber)
	cons, _ := c.GetConsensusState(heightAtSlot(slot))
	urequire.True(t, bytes.Equal(ex.StateRoot, cons.StateRoot))
}

// A membership path must have exactly one element: none is refused, not a
// panic.
func TestMembershipPathLength(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	c.UpdateState(hdr)
	height := c.LatestHeight()
	urequire.ErrorContains(t, c.VerifyNonMembershipProof(height, MembershipProof{}, types.MerklePath{}), "path must have exactly one element, got 0")
	two := types.MerklePath{KeyPath: [][]byte{{1}, {2}}}
	urequire.ErrorContains(t, c.VerifyNonMembershipProof(height, MembershipProof{}, two), "path must have exactly one element, got 2")
}

// Explicit misbehaviour: both updates are validated against the trusted state.
// A genuinely valid conflicting pair would need two 2/3-signed updates
// finalizing different headers at one slot, which the recorded data cannot
// give; so each case here pairs the fixture's valid update with a copy whose
// finalized header differs at the same slot, failing its finality proof, and
// the refusal names the update that failed.
func TestMisbehaviourValidatesBothUpdates(t *testing.T) {
	c, hdr := firstUpdate(t, fixtureErc20())
	valid := hdr.ConsensusUpdate
	forged := valid
	forged.FinalizedHeader.Beacon.StateRoot = flip(forged.FinalizedHeader.Beacon.StateRoot, 0)

	m := &Misbehaviour{TrustedSlot: hdr.TrustedSlot, Update1: valid, Update2: forged}
	urequire.ErrorContains(t, c.VerifyClientMessage(m), "update 2: invalid finality branch")
	m = &Misbehaviour{TrustedSlot: hdr.TrustedSlot, Update1: forged, Update2: valid}
	urequire.ErrorContains(t, c.VerifyClientMessage(m), "update 1: invalid finality branch")
}
