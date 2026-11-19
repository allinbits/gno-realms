package arc

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
)

// The synthetic data (zz_synthetic_test.gno) is written by
// cmd/gen-arc-synthetic from Arc's and Ethereum's definitions (RLP headers,
// Merkle-Patricia tries, the registry's Solidity storage layout, the SSZ
// vote), independently of this package, and signed with Ed25519 keys from a
// fixed seed: the cases the testnet fixture cannot give, a validator set
// that changes and packet commitment proofs.

func h(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// syntheticMember is a validator of a synthetic set: the index of its key
// in syntheticPubKeys and its power.
type syntheticMember struct {
	key   int
	power uint64
}

// syntheticCommitment is a router commitment proof at Height, of the packet
// commitment at Path (Value nil: proven absent).
type syntheticCommitment struct {
	Height, Sequence uint64
	Path, Value      []byte
	Proof            ethereum.MembershipProof
}

// newSyntheticClient is a client created at block 100, whose set is
// syntheticTrusted: total power 9, trust level 1/3.
func newSyntheticClient(t *testing.T) *ArcLightClient {
	t.Helper()
	setTime(syntheticTime)
	cs, cons, err := DecodeCreation(syntheticCreation)
	if err != nil {
		t.Fatalf("creation: %v", err)
	}
	if err := cs.ValidateBasic(); err != nil {
		t.Fatal(err)
	}
	if err := cons.ValidateBasic(); err != nil {
		t.Fatal(err)
	}
	if cons.Height != syntheticCreationHeight {
		t.Fatalf("creation height %d", cons.Height)
	}
	c := NewArcLightClient()
	if err := c.Initialize(cs, cons); err != nil {
		t.Fatal(err)
	}
	return c
}

// syntheticHeader decodes a synthetic header and keeps the precommits of
// the keys signers only.
func syntheticHeader(t *testing.T, msg []byte, signers ...int) *Header {
	t.Helper()
	hdr, err := DecodeHeader(msg)
	if err != nil {
		t.Fatal(err)
	}
	var kept []CommitSignature
	for _, i := range signers {
		addr := addressOf(syntheticPubKeys[i])
		found := false
		for _, s := range hdr.Certificate.Signatures {
			if bytes.Equal(s.Address, addr) {
				kept = append(kept, s)
				found = true
			}
		}
		if !found {
			t.Fatalf("no precommit by key %d", i)
		}
	}
	hdr.Certificate.Signatures = kept
	return hdr
}

// checkSet requires vs to be want: the same keys, in order, with the same
// powers.
func checkSet(t *testing.T, name string, vs *ValidatorSet, want []syntheticMember) {
	t.Helper()
	if len(vs.Validators) != len(want) {
		t.Fatalf("%s: %d validators, want %d", name, len(vs.Validators), len(want))
	}
	var total uint64
	for i, m := range want {
		v := vs.Validators[i]
		if !bytes.Equal(v.PubKey, syntheticPubKeys[m.key]) || v.Power != m.power {
			t.Fatalf("%s: validator %d has power %d, want key %d with power %d", name, i, v.Power, m.key, m.power)
		}
		total += m.power
	}
	if vs.TotalPower != total {
		t.Fatalf("%s: total power %d, want %d", name, vs.TotalPower, total)
	}
}

// The creation reads the registry's set: six validators (key 0 with power
// 4, keys 1 to 5 with 1), key 8, active with no power, skipped.
func TestSyntheticCreation(t *testing.T) {
	c := newSyntheticClient(t)
	cons, _ := c.GetConsensusState(c.LatestHeight())
	checkSet(t, "trusted", cons.NextValidators, syntheticTrusted)
}

// trustCase is an update with the precommits of signers, refused with an
// error containing want, or accepted when want is empty.
type trustCase struct {
	name    string
	signers []int
	want    string
}

// runTrustCases runs each case from a new synthetic client, at trust level
// (1/3 when nil), with the header msg proving block height whose registry
// holds set. An accepted update must store that set, read anew.
func runTrustCases(t *testing.T, msg []byte, height uint64, set []syntheticMember, level *Fraction, cases []trustCase) {
	t.Helper()
	for _, tc := range cases {
		c := newSyntheticClient(t)
		if level != nil {
			cs := *c.ClientState
			cs.TrustLevel = *level
			c.ClientState = &cs
		}
		trusted, _ := c.GetConsensusState(c.LatestHeight())
		hdr := syntheticHeader(t, msg, tc.signers...)
		err := c.VerifyClientMessage(hdr)
		if tc.want != "" {
			if err == nil {
				t.Fatalf("%s: accepted", tc.name)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("%s: %v, want %q", tc.name, err, tc.want)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		c.UpdateState(hdr)
		if c.LatestHeight() != types.NewHeight(0, height) {
			t.Fatalf("%s: latest height %s", tc.name, c.LatestHeight().String())
		}
		cons, _ := c.GetConsensusState(c.LatestHeight())
		// T's set (its members and powers, in any order) is shared as
		// stored; any other is stored anew.
		same := sameMembers(set, syntheticTrusted)
		if shared := cons.NextValidators == trusted.NextValidators; shared != same {
			t.Fatalf("%s: trusted set shared %v", tc.name, shared)
		}
		if same {
			set = syntheticTrusted
		}
		checkSet(t, tc.name, cons.NextValidators, set)
	}
}

// sameMembers reports whether a and b hold the same keys with the same
// powers, in any order.
func sameMembers(a, b []syntheticMember) bool {
	if len(a) != len(b) {
		return false
	}
	for _, m := range a {
		found := false
		for _, n := range b {
			if m == n {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

const (
	notTrusted = "not enough trusted voting power"
	notQuorum  = "not enough voting power"
)

// TestSyntheticRotationTrustLevel updates across a rotated set: block 110's
// registry drops keys 4 and 5, adds 6 (power 3) and 7 (power 2) and changes
// every kept power (key 0 from 4 to 1, keys 1 to 3 from 1 to 3), a total
// of 15. Every case below has more than 2/3 of the rotated set unless it
// says otherwise; what decides is the share of the trusted set (total 9,
// level 1/3: more than 3 needed), counted by the trusted set's powers.
func TestSyntheticRotationTrustLevel(t *testing.T) {
	runTrustCases(t, syntheticRotation, syntheticRotationHeight, syntheticRotated, nil, []trustCase{
		// Keys 1 and 2 hold 2 of T's 9 (but 6 of the rotated set's
		// powers, which must not count for the trust check). Rotated: 11 of 15.
		{"trusted power below the level", []int{1, 2, 6, 7}, notTrusted},
		// Keys 1, 2, 3: 3 of 9, exactly 1/3, which is not more. Rotated: 12.
		{"trusted power exactly at the level", []int{1, 2, 3, 6}, notTrusted},
		// The same and key 4, rotated out but in T: 4 of 9. Rotated: 12.
		{"trusted power just above the level", []int{1, 2, 3, 4, 6}, ""},
		// Key 0 (4 in T, 1 now), 2, 3: 6 of 9. Rotated: 12.
		{"trusted power above the level", []int{0, 2, 3, 6, 7}, ""},
		// 7 of T's 9, but 10 of the rotated 15: exactly 2/3.
		{"rotated set exactly at 2/3", []int{0, 1, 2, 3}, notQuorum},
		// 8 of T's 9 (4 from the rotated-out keys), 7 of the rotated 15.
		{"rotated set below 2/3", []int{0, 1, 2, 4, 5}, notQuorum},
	})
}

// TestSyntheticReweight updates to block 120, whose registry holds T's
// validators with other powers only (key 0 from 4 to 1, key 1 from 1 to
// 7; total 12): the membership is T's, the set is not.
func TestSyntheticReweight(t *testing.T) {
	runTrustCases(t, syntheticReweight, syntheticReweightHeight, syntheticReweighted, nil, []trustCase{
		// 3 of T's 9, exactly 1/3; 9 of the new 12 (by T's powers: 3).
		{"trusted power exactly at the level", []int{1, 2, 3}, notTrusted},
		// 4 of T's 9; 10 of 12.
		{"trusted power above the level", []int{1, 2, 3, 4}, ""},
		// 8 of T's 9, more than 2/3 by T's powers, but 5 of the new 12.
		{"new powers below 2/3", []int{0, 2, 3, 4, 5}, notQuorum},
	})
}

// TestSyntheticIdleSharesSet updates to block 130, whose registry's storage
// changed while the set it holds did not: the new consensus state shares
// the trusted set, stored once, rather than a copy.
func TestSyntheticIdleSharesSet(t *testing.T) {
	c := newSyntheticClient(t)
	trusted, _ := c.GetConsensusState(heightAt(syntheticCreationHeight))
	if err := update(c, syntheticHeader(t, syntheticIdle, 0, 1, 2, 3, 4, 5)); err != nil {
		t.Fatal(err)
	}
	got, ok := c.GetConsensusState(heightAt(syntheticIdleHeight))
	if !ok {
		t.Fatal("no consensus state at the idle block")
	}
	if bytes.Equal(got.RegistryStorageRoot, trusted.RegistryStorageRoot) {
		t.Fatal("the idle block's registry storage root should differ")
	}
	checkSet(t, "idle", got.NextValidators, syntheticIdled)
	if got.NextValidators != trusted.NextValidators {
		t.Fatal("an unchanged set was copied, not shared")
	}
}

// TestSyntheticIdleNoTrustCheck: at block 130 the set is T's under another
// registry root, so only its 2/3 quorum applies, not the trust level: at
// level 9/10, keys 0 to 3 (7 of 9) suffice, and 6 of 9 do not.
func TestSyntheticIdleNoTrustCheck(t *testing.T) {
	level := Fraction{9, 10}
	runTrustCases(t, syntheticIdle, syntheticIdleHeight, syntheticIdled, &level, []trustCase{
		{"exactly 2/3", []int{0, 1, 3}, notQuorum},
		{"above 2/3, below the trust level", []int{0, 1, 2, 3}, ""},
	})
}

// TestSyntheticReorderNoTrustCheck: at block 140 the registry holds T's
// validators and powers in another order, which is T's set: only its 2/3
// quorum applies, and the stored state shares T's set.
func TestSyntheticReorderNoTrustCheck(t *testing.T) {
	level := Fraction{9, 10}
	runTrustCases(t, syntheticReorder, syntheticReorderHeight, syntheticReordered, &level, []trustCase{
		{"exactly 2/3", []int{0, 1, 3}, notQuorum},
		{"above 2/3, below the trust level", []int{0, 1, 2, 3}, ""},
	})
}

// TestSyntheticTrustLevelParameter runs the rotation at trust level 2/3: the
// client's level, not a constant, decides.
func TestSyntheticTrustLevelParameter(t *testing.T) {
	level := Fraction{2, 3}
	runTrustCases(t, syntheticRotation, syntheticRotationHeight, syntheticRotated, &level, []trustCase{
		// 4 of 9: above 1/3, below 2/3.
		{"above 1/3, below 2/3", []int{1, 2, 3, 4, 6}, notTrusted},
		// 6 of 9: exactly 2/3.
		{"exactly 2/3", []int{0, 2, 3, 6, 7}, notTrusted},
		// 7 of 9; every rotated key signs.
		{"above 2/3", []int{0, 1, 2, 3, 6, 7}, ""},
	})
}

func syntheticCommitmentAt(t *testing.T, height, seq uint64) syntheticCommitment {
	t.Helper()
	for _, c := range syntheticCommitments {
		if c.Height == height && c.Sequence == seq {
			return c
		}
	}
	t.Fatalf("no synthetic commitment %d at %d", seq, height)
	return syntheticCommitment{}
}

func pathOf(p []byte) types.MerklePath { return types.MerklePath{KeyPath: [][]byte{p}} }

func expectProofError(t *testing.T, name string, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s: accepted", name)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("%s: %v, want %q", name, err, want)
	}
}

// checkProofs verifies every synthetic proof at height on c: a stored
// commitment's membership and its value, an absent one's non-membership,
// and neither the other way round.
func checkProofs(t *testing.T, c *ArcLightClient, height uint64) {
	t.Helper()
	at := types.NewHeight(0, height)
	n := 0
	for _, p := range syntheticCommitments {
		if p.Height != height {
			continue
		}
		n++
		path := pathOf(p.Path)
		got, err := c.ProvenValue(at, p.Proof.Encode(), path)
		if err != nil {
			t.Fatalf("packet %d at %d: %v", p.Sequence, height, err)
		}
		if p.Value == nil {
			if !bytes.Equal(got, make([]byte, 32)) {
				t.Fatalf("packet %d at %d: absent, proven %x", p.Sequence, height, got)
			}
			if err := c.VerifyNonMembership(at, p.Proof.Encode(), path); err != nil {
				t.Fatalf("absence of packet %d at %d: %v", p.Sequence, height, err)
			}
			// Any commitment (a hash, never zero: storage cannot tell a
			// zero word from an unset one).
			expectProofError(t, "membership of an absent packet", c.VerifyMembership(at, p.Proof.Encode(), path, bytes.Repeat([]byte{1}, 32)), "differs")
			continue
		}
		if !bytes.Equal(got, p.Value) {
			t.Fatalf("packet %d at %d: proven %x, want %x", p.Sequence, height, got, p.Value)
		}
		if err := c.VerifyMembership(at, p.Proof.Encode(), path, p.Value); err != nil {
			t.Fatalf("packet %d at %d: %v", p.Sequence, height, err)
		}
		expectProofError(t, "absence of a stored packet", c.VerifyNonMembership(at, p.Proof.Encode(), path), "a commitment is stored")
	}
	if n != 3 {
		t.Fatalf("%d synthetic proofs at %d", n, height)
	}
}

// TestSyntheticMembership verifies the router's commitments (packets 1 and
// 2) and the absence of packet 3 against block 100's state root.
func TestSyntheticMembership(t *testing.T) {
	checkProofs(t, newSyntheticClient(t), syntheticCreationHeight)
}

// TestSyntheticMembershipRefusals: a proof is refused for any other value,
// path, state root, router, commitment slot or height than its own.
func TestSyntheticMembershipRefusals(t *testing.T) {
	c := newSyntheticClient(t)
	at := types.NewHeight(0, syntheticCreationHeight)
	one := syntheticCommitmentAt(t, syntheticCreationHeight, 1)
	two := syntheticCommitmentAt(t, syntheticCreationHeight, 2)
	three := syntheticCommitmentAt(t, syntheticCreationHeight, 3)

	wrong := cloneBytes(one.Value)
	wrong[31] ^= 1
	expectProofError(t, "wrong value", c.VerifyMembership(at, one.Proof.Encode(), pathOf(one.Path), wrong), "differs")
	expectProofError(t, "another packet's value", c.VerifyMembership(at, one.Proof.Encode(), pathOf(one.Path), two.Value), "differs")
	expectProofError(t, "short value", c.VerifyMembership(at, one.Proof.Encode(), pathOf(one.Path), one.Value[:31]), "32 bytes")

	// Packet 1's proof does not reach packet 2's slot, nor packet 3's
	// absence proof packet 1's.
	expectProofError(t, "wrong path", c.VerifyMembership(at, one.Proof.Encode(), pathOf(two.Path), two.Value), "")
	if err := c.VerifyNonMembership(at, three.Proof.Encode(), pathOf(one.Path)); err == nil {
		t.Fatal("an absence proof of packet 3 proved packet 1 absent")
	}
	expectProofError(t, "two-element path", c.VerifyMembership(at, one.Proof.Encode(), types.MerklePath{KeyPath: [][]byte{one.Path, one.Path}}, one.Value), "exactly one element")

	// Block 110's proofs of the same commitments, into another state root.
	other := syntheticCommitmentAt(t, syntheticRotationHeight, 1)
	expectProofError(t, "another state root", c.VerifyMembership(at, other.Proof.Encode(), pathOf(other.Path), other.Value), "account proof")
	expectProofError(t, "another state root (absence)", c.VerifyNonMembership(at, syntheticCommitmentAt(t, syntheticRotationHeight, 3).Proof.Encode(), pathOf(three.Path)), "account proof")

	// A truncated storage proof.
	cut := one.Proof
	cut.StorageProof = cut.StorageProof[:len(cut.StorageProof)-1]
	expectProofError(t, "truncated storage proof", c.VerifyMembership(at, cut.Encode(), pathOf(one.Path), one.Value), "storage proof")
	expectProofError(t, "not a membership proof", c.VerifyMembership(at, []byte("proof"), pathOf(one.Path), one.Value), "")
	expectProofError(t, "trailing bytes", c.VerifyMembership(at, append(one.Proof.Encode(), 0), pathOf(one.Path), one.Value), "")

	// Heights: none above the latest, no revision but 0, none never stored.
	expectProofError(t, "height above the latest", c.VerifyMembership(types.NewHeight(0, syntheticCreationHeight+1), one.Proof.Encode(), pathOf(one.Path), one.Value), "after the latest height")
	expectProofError(t, "revision 1", c.VerifyMembership(types.NewHeight(1, syntheticCreationHeight), one.Proof.Encode(), pathOf(one.Path), one.Value), "revision number")
	expectProofError(t, "no consensus state", c.VerifyMembership(types.NewHeight(0, syntheticCreationHeight-1), one.Proof.Encode(), pathOf(one.Path), one.Value), "no consensus state")

	// Another router, or another commitment slot, is not the one proven.
	for _, mutate := range []func(cs *ClientState){
		func(cs *ClientState) {
			cs.IBCContractAddress = cloneBytes(cs.IBCContractAddress)
			cs.IBCContractAddress[0] ^= 1
		},
		func(cs *ClientState) {
			cs.IBCCommitmentSlot = cloneBytes(cs.IBCCommitmentSlot)
			cs.IBCCommitmentSlot[0] ^= 1
		},
	} {
		d := newSyntheticClient(t)
		cs := *d.ClientState
		mutate(&cs)
		d.ClientState = &cs
		if err := d.VerifyMembership(at, one.Proof.Encode(), pathOf(one.Path), one.Value); err == nil {
			t.Fatal("a proof of another router or commitment slot was accepted")
		}
	}
}

// TestSyntheticProofsAfterUpdate verifies proofs at both heights of a client
// updated to block 110, each against its own block's state root.
func TestSyntheticProofsAfterUpdate(t *testing.T) {
	c := newSyntheticClient(t)
	if err := update(c, syntheticHeader(t, syntheticRotation, 0, 2, 3, 6, 7)); err != nil {
		t.Fatal(err)
	}
	checkProofs(t, c, syntheticCreationHeight)
	checkProofs(t, c, syntheticRotationHeight)
	p := syntheticCommitmentAt(t, syntheticCreationHeight, 1)
	expectProofError(t, "block 100's proof at block 110", c.VerifyMembership(types.NewHeight(0, syntheticRotationHeight), p.Proof.Encode(), pathOf(p.Path), p.Value), "account proof")
}

// TestSyntheticProofsAfterRecovery: a recovery from a substitute at block
// 110 makes the subject's states below 110 untrusted (TrustedFromHeight):
// a valid proof at block 100 is refused afterwards, one at 110 verifies.
func TestSyntheticProofsAfterRecovery(t *testing.T) {
	subject := newSyntheticClient(t)
	checkProofs(t, subject, syntheticCreationHeight)
	sub := newSyntheticClient(t)
	if err := update(sub, syntheticHeader(t, syntheticRotation, 0, 2, 3, 6, 7)); err != nil {
		t.Fatal(err)
	}
	if err := subject.RecoverClient(sub); err != nil {
		t.Fatalf("recovery: %v", err)
	}
	if subject.TrustedFromHeight != syntheticRotationHeight {
		t.Fatalf("trusted from %d", subject.TrustedFromHeight)
	}
	for _, p := range syntheticCommitments {
		if p.Height != syntheticCreationHeight {
			continue
		}
		at := types.NewHeight(0, p.Height)
		if p.Value == nil {
			expectProofError(t, "absence below the recovery", subject.VerifyNonMembership(at, p.Proof.Encode(), pathOf(p.Path)), "no consensus state")
		} else {
			expectProofError(t, "membership below the recovery", subject.VerifyMembership(at, p.Proof.Encode(), pathOf(p.Path), p.Value), "no consensus state")
		}
		if _, err := subject.ProvenValue(at, p.Proof.Encode(), pathOf(p.Path)); err == nil {
			t.Fatal("a value proven below the recovery")
		}
	}
	checkProofs(t, subject, syntheticRotationHeight)
}

// Equal compares members and powers in any order.
func TestValidatorSetEqual(t *testing.T) {
	k := syntheticPubKeys
	set := func(keys []int, powers ...uint64) *ValidatorSet {
		t.Helper()
		var pks [][]byte
		for _, i := range keys {
			pks = append(pks, k[i])
		}
		vs, err := NewValidatorSet(pks, powers)
		if err != nil {
			t.Fatal(err)
		}
		return vs
	}
	a := set([]int{0, 1, 2}, 4, 1, 1)
	for _, tc := range []struct {
		name string
		o    *ValidatorSet
		want bool
	}{
		{"same order", set([]int{0, 1, 2}, 4, 1, 1), true},
		{"another order", set([]int{2, 0, 1}, 1, 4, 1), true},
		{"powers swapped", set([]int{0, 1, 2}, 1, 4, 1), false},
		{"another key", set([]int{0, 1, 3}, 4, 1, 1), false},
		{"one fewer", set([]int{0, 1}, 4, 1), false},
		{"one more", set([]int{0, 1, 2, 3}, 4, 1, 1, 1), false},
	} {
		if a.Equal(tc.o) != tc.want || tc.o.Equal(a) != tc.want {
			t.Errorf("%s: Equal is not %v", tc.name, tc.want)
		}
	}
}
