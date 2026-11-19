package arc

import (
	"strings"
	"testing"

	"gno.land/p/aib/ibc/types/v0"
)

// withStates returns a synthetic client holding consensus states at blocks
// 100, 100+step, ..., 100+(n-1)*step, each step seconds after the previous,
// its latest height the last of them, and the time at which a state of
// timestamp ts is exactly TrustingPeriod seconds old (expired).
func withStates(t *testing.T, n int, step uint64) (*ArcLightClient, func(ts uint64) int64) {
	t.Helper()
	c := newSyntheticClient(t)
	base, _ := c.GetConsensusState(heightAt(syntheticCreationHeight))
	for i := 1; i < n; i++ {
		cons := copyConsensusState(*base)
		cons.Height = base.Height + uint64(i)*step
		cons.Timestamp = base.Timestamp + uint64(i)*step
		c.setConsensusState(&cons)
	}
	cs := *c.ClientState
	cs.LatestHeight = base.Height + uint64(n-1)*step
	c.ClientState = &cs
	expiredAt := func(ts uint64) int64 { return int64(ts + cs.TrustingPeriod) }
	return c, expiredAt
}

func oldestHeight(c *ArcLightClient) uint64 {
	_, v := c.ConsensusStateByHeight.GetByIndex(0)
	return v.(*ConsensusState).Height
}

func stateAt(t *testing.T, c *ArcLightClient, height uint64) *ConsensusState {
	t.Helper()
	cons, ok := c.GetConsensusState(heightAt(height))
	if !ok {
		t.Fatalf("no consensus state at %d", height)
	}
	return cons
}

// A consensus state is pruned once it is past the trusting period, oldest
// first, one per call, and never before.
func TestPruneOldestConsensusState(t *testing.T) {
	c, expiredAt := withStates(t, 4, 100)
	base := oldestHeight(c)
	ts := stateAt(t, c, base).Timestamp

	setTime(expiredAt(ts) - 1) // the last second of base's trusting period
	if c.pruneOldestConsensusState() {
		t.Fatal("pruned a state still in its trusting period")
	}
	if n := c.ConsensusStateByHeight.Size(); n != 4 {
		t.Fatalf("%d states, want 4", n)
	}

	setTime(expiredAt(ts + 100))
	if !c.pruneOldestConsensusState() {
		t.Fatal("kept an expired state")
	}
	if got := oldestHeight(c); got != base+100 {
		t.Fatalf("oldest %d, want %d: only the oldest is removed per call", got, base+100)
	}
	if !c.pruneOldestConsensusState() {
		t.Fatal("kept an expired state")
	}
	if c.pruneOldestConsensusState() {
		t.Fatal("pruned a state still in its trusting period")
	}
	if got := oldestHeight(c); got != base+200 {
		t.Fatalf("oldest %d, want %d", got, base+200)
	}
}

// The latest consensus state is never pruned, even once the client expired:
// Status, recoveries and renders read it.
func TestPruneKeepsLatest(t *testing.T) {
	c, expiredAt := withStates(t, 3, 100)
	setTime(expiredAt(stateAt(t, c, c.ClientState.LatestHeight).Timestamp) + 1000)
	if s := string(c.Status()); s != "Expired" {
		t.Fatalf("status %s", s)
	}
	if n := c.PruneExpiredConsensusStates(10); n != 2 {
		t.Fatalf("pruned %d, want 2", n)
	}
	if _, ok := c.GetConsensusState(c.LatestHeight()); !ok || c.ConsensusStateByHeight.Size() != 1 {
		t.Fatal("the latest consensus state was removed")
	}
	if n := c.PruneExpiredConsensusStates(10); n != 0 {
		t.Fatalf("pruned %d more", n)
	}
}

// The bulk prune removes every expired state up to its limit and stops at
// the first one still in its trusting period.
func TestPruneExpiredConsensusStates(t *testing.T) {
	c, expiredAt := withStates(t, 10, 100)
	base := oldestHeight(c)
	setTime(expiredAt(stateAt(t, c, base+600).Timestamp)) // base..base+600 expired: 7 states

	if n := c.PruneExpiredConsensusStates(3); n != 3 {
		t.Fatalf("pruned %d, want 3: the limit bounds a batch", n)
	}
	if got := oldestHeight(c); got != base+300 {
		t.Fatalf("oldest %d", got)
	}
	if n := c.PruneExpiredConsensusStates(100); n != 4 {
		t.Fatalf("pruned %d, want 4", n)
	}
	if got := oldestHeight(c); got != base+700 {
		t.Fatalf("oldest %d", got)
	}
	if n := c.PruneExpiredConsensusStates(100); n != 0 {
		t.Fatalf("pruned %d more", n)
	}
	if n := NewArcLightClient().PruneExpiredConsensusStates(100); n != 0 {
		t.Fatal("pruned an empty client")
	}
}

// A state below TrustedFromHeight, from before a recovery, is pruned
// whatever its age: nothing reads it again.
func TestPruneBelowTrustedFromHeight(t *testing.T) {
	c, _ := withStates(t, 4, 100)
	base := oldestHeight(c)
	setTime(syntheticTime) // every state in its trusting period
	c.TrustedFromHeight = base + 200
	if n := c.PruneExpiredConsensusStates(10); n != 2 {
		t.Fatalf("pruned %d, want 2", n)
	}
	if got := oldestHeight(c); got != base+200 {
		t.Fatalf("oldest %d: the state at TrustedFromHeight is kept", got)
	}
}

// UpdateState prunes on the way: a state left below a recovery's
// TrustedFromHeight is removed by the next update, the trusted one kept.
func TestUpdateStatePrunes(t *testing.T) {
	c := newSyntheticClient(t)
	trusted := stateAt(t, c, syntheticCreationHeight)
	stale := copyConsensusState(*trusted)
	stale.Height = syntheticCreationHeight - 1
	c.setConsensusState(&stale)
	c.TrustedFromHeight = syntheticCreationHeight

	if err := update(c, syntheticHeader(t, syntheticIdle, 0, 1, 2, 3, 4, 5)); err != nil {
		t.Fatal(err)
	}
	if n := c.ConsensusStateByHeight.Size(); n != 2 {
		t.Fatalf("%d states, want 2", n)
	}
	if got := oldestHeight(c); got != syntheticCreationHeight {
		t.Fatalf("oldest %d", got)
	}
}

// A proof at a height whose state is past the trusting period is refused
// whether or not that state was pruned yet; one second earlier it verifies.
func TestProofRefusedPastTrustingPeriod(t *testing.T) {
	c := newSyntheticClient(t)
	at := types.NewHeight(0, syntheticCreationHeight)
	one := syntheticCommitmentAt(t, syntheticCreationHeight, 1)
	three := syntheticCommitmentAt(t, syntheticCreationHeight, 3)
	expiredAt := int64(stateAt(t, c, syntheticCreationHeight).Timestamp + c.ClientState.TrustingPeriod)

	setTime(expiredAt - 1)
	if err := c.VerifyMembershipProof(at, one.Proof, types.MerklePath{KeyPath: [][]byte{one.Path}}, one.Value); err != nil {
		t.Fatalf("within the trusting period: %v", err)
	}
	if err := c.VerifyNonMembershipProof(at, three.Proof, types.MerklePath{KeyPath: [][]byte{three.Path}}); err != nil {
		t.Fatalf("absence within the trusting period: %v", err)
	}

	setTime(expiredAt)
	if _, ok := c.GetConsensusState(at); !ok {
		t.Fatal("the state should still be stored")
	}
	err := c.VerifyMembershipProof(at, one.Proof, types.MerklePath{KeyPath: [][]byte{one.Path}}, one.Value)
	if err == nil || !strings.Contains(err.Error(), "seconds old") {
		t.Fatalf("membership past the trusting period: %v", err)
	}
	err = c.VerifyNonMembershipProof(at, three.Proof, types.MerklePath{KeyPath: [][]byte{three.Path}})
	if err == nil || !strings.Contains(err.Error(), "seconds old") {
		t.Fatalf("absence past the trusting period: %v", err)
	}
}
