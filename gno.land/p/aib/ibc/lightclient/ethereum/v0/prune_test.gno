package ethereum

import (
	"strings"
	"testing"

	"gno.land/p/nt/urequire/v0"
)

// withStates returns a client initialized from the native fixture holding
// consensus states at slots base, base+step, ..., base+(n-1)*step (base is
// the fixture's bootstrap slot), its latest slot the last of them, and the
// time at which a slot is exactly one slot past its trust window.
func withStates(t *testing.T, n int, step uint64) (*EthLightClient, func(slot uint64) uint64) {
	f := fixtureNative()
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	base := f.consensusState
	for i := 1; i < n; i++ {
		cons := copyConsensusState(base)
		cons.Slot = base.Slot + uint64(i)*step
		c.setConsensusState(&cons)
	}
	cs := *c.ClientState
	cs.LatestSlot = base.Slot + uint64(n-1)*step
	c.ClientState = &cs
	expiredAt := func(slot uint64) uint64 {
		return cs.GenesisTime + (slot-cs.GenesisSlot+cs.trustWindow()+1)*cs.SecondsPerSlot
	}
	return c, expiredAt
}

func oldestSlot(c *EthLightClient) uint64 {
	_, v := c.ConsensusStateByHeight.GetByIndex(0)
	return v.(*ConsensusState).Slot
}

// A consensus state is pruned once it is past the trust window, oldest first,
// one per call, and never before.
func TestPruneOldestConsensusState(t *testing.T) {
	c, expiredAt := withStates(t, 4, 100)
	base := oldestSlot(c)

	setNow(expiredAt(base) - c.ClientState.SecondsPerSlot) // the last slot of base's window
	urequire.False(t, c.pruneOldestConsensusState(), "pruned a state still in its window")
	urequire.Equal(t, 4, c.ConsensusStateByHeight.Size())

	setNow(expiredAt(base + 100))
	urequire.True(t, c.pruneOldestConsensusState())
	urequire.Equal(t, base+100, oldestSlot(c), "only the oldest is removed per call")
	urequire.True(t, c.pruneOldestConsensusState())
	urequire.False(t, c.pruneOldestConsensusState(), "pruned a state still in its window")
	urequire.Equal(t, base+200, oldestSlot(c))
}

// The latest consensus state is never pruned, even once the client expired:
// Status, recoveries and renders read it.
func TestPruneKeepsLatest(t *testing.T) {
	c, expiredAt := withStates(t, 3, 100)
	setNow(expiredAt(c.ClientState.LatestSlot) + 1000)
	urequire.Equal(t, "Expired", string(c.Status()))
	urequire.Equal(t, 2, c.PruneExpiredConsensusStates(10))
	urequire.Equal(t, 1, c.ConsensusStateByHeight.Size())
	_, ok := c.GetConsensusState(c.LatestHeight())
	urequire.True(t, ok, "latest consensus state removed")
	urequire.Equal(t, 0, c.PruneExpiredConsensusStates(10))
}

// The bulk prune removes every expired state up to its limit and stops at
// the first one still in its window.
func TestPruneExpiredConsensusStates(t *testing.T) {
	c, expiredAt := withStates(t, 10, 100)
	base := oldestSlot(c)
	setNow(expiredAt(base + 600)) // slots base..base+600 expired: 7 states

	urequire.Equal(t, 3, c.PruneExpiredConsensusStates(3), "the limit bounds a batch")
	urequire.Equal(t, base+300, oldestSlot(c))
	urequire.Equal(t, 4, c.PruneExpiredConsensusStates(100))
	urequire.Equal(t, base+700, oldestSlot(c))
	urequire.Equal(t, 0, c.PruneExpiredConsensusStates(100))
	urequire.Equal(t, 0, NewEthLightClient().PruneExpiredConsensusStates(100), "empty client")
}

// A state below TrustedFromSlot, from before a recovery, is pruned whatever
// its age: nothing reads it again.
func TestPruneBelowTrustedFromSlot(t *testing.T) {
	c, expiredAt := withStates(t, 4, 100)
	base := oldestSlot(c)
	setNow(expiredAt(base) - 100*c.ClientState.SecondsPerSlot) // every state in its window
	c.TrustedFromSlot = base + 200
	urequire.Equal(t, 2, c.PruneExpiredConsensusStates(10))
	urequire.Equal(t, base+200, oldestSlot(c), "the state at TrustedFromSlot is kept")
}

// UpdateState prunes on the way: a state left below a recovery's
// TrustedFromSlot is removed by the next update, the trusted one kept.
func TestUpdateStatePrunes(t *testing.T) {
	f := fixtureErc20()
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	stale := copyConsensusState(f.consensusState)
	stale.Slot = f.consensusState.Slot - 1
	c.setConsensusState(&stale)
	c.TrustedFromSlot = f.consensusState.Slot

	hdr := updates(f)[0]
	urequire.NoError(t, verifyAt(c, hdr))
	c.UpdateState(hdr)
	urequire.Equal(t, 2, c.ConsensusStateByHeight.Size())
	urequire.Equal(t, f.consensusState.Slot, oldestSlot(c))
}

// A proof at a slot past the trust window is refused whether or not its
// state was pruned yet, and whatever store holds it: a retired verifier's
// history is never pruned.
func TestProofRefusedPastTrustWindow(t *testing.T) {
	old, expiredAt := withStates(t, 3, 100)
	base := oldestSlot(old)
	c := NewFrom(Retire(old))
	value := make([]byte, hashSize)
	path := ethPath([]byte("key"))

	setNow(expiredAt(base))
	_, ok := c.GetConsensusState(heightAtSlot(base))
	urequire.True(t, ok, "the retired verifier's state is still stored")
	urequire.ErrorContains(t, c.VerifyMembership(heightAtSlot(base), MembershipProof{}.Encode(), path, value),
		"sync committee periods old")
	urequire.ErrorContains(t, c.VerifyNonMembership(heightAtSlot(base), MembershipProof{}.Encode(), path),
		"sync committee periods old")
	// One slot earlier the window still covers it: the proof is checked.
	setNow(expiredAt(base) - c.ClientState.SecondsPerSlot)
	err := c.VerifyNonMembership(heightAtSlot(base), MembershipProof{}.Encode(), path)
	urequire.Error(t, err)
	urequire.False(t, strings.Contains(err.Error(), "sync committee periods old"), err.Error())
}
