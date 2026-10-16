package ethereum

import (
	"testing"

	"gno.land/p/nt/urequire/v0"
)

// migrateClient is an Active client of the native fixture (slots of 2 s,
// epochs of 8 slots), with the block time set to the slot given.
func migrateClient(t *testing.T, slot uint64) *EthLightClient {
	f := fixtureNative()
	c := NewEthLightClient()
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))
	cs := c.ClientState
	setNow(cs.GenesisTime + (slot-cs.GenesisSlot)*cs.SecondsPerSlot)
	urequire.Equal(t, "Active", string(c.Status()))
	return c
}

func TestMigrateForkParameters(t *testing.T) {
	// Latest trusted slot 64 (epoch 8); the block time at slot 70 (epoch 8).
	c := migrateClient(t, 70)
	old := c.ClientState.ForkParameters
	before := c.ClientState
	cons, ok := c.GetConsensusState(c.LatestHeight())
	urequire.True(t, ok)

	fp := old
	fp.Gloas = Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 12}
	urequire.NoError(t, c.MigrateForkParameters(fp))
	urequire.True(t, c.ClientState.ForkParameters == fp, "schedule replaced")
	urequire.True(t, before.ForkParameters == old, "the previous client state is not written in place")
	urequire.Equal(t, before.LatestSlot, c.ClientState.LatestSlot)
	after, ok := c.GetConsensusState(c.LatestHeight())
	urequire.True(t, ok && after == cons, "consensus states kept")
	urequire.Equal(t, "Active", string(c.Status()))

	// Rescheduling a fork that is not active yet is fine; reverting to the old
	// schedule too.
	fp.Gloas.Epoch = 20
	urequire.NoError(t, c.MigrateForkParameters(fp))
	urequire.NoError(t, c.MigrateForkParameters(old))
}

func TestMigrateForkParametersRefusals(t *testing.T) {
	c := migrateClient(t, 70) // current epoch 8
	old := c.ClientState.ForkParameters
	cases := []struct {
		name   string
		mutate func(p *ForkParameters)
		err    string
	}{
		{"unchanged", func(p *ForkParameters) {}, "unchanged"},
		{"genesis version", func(p *ForkParameters) { p.GenesisForkVersion[0]++ }, "genesis"},
		{"genesis slot", func(p *ForkParameters) { p.GenesisSlot++ }, "genesis"},
		{"active fork epoch", func(p *ForkParameters) { p.Fulu.Epoch = 2 }, "fork fulu is active"},
		{"active fork version", func(p *ForkParameters) { p.Electra.Version[3]++ }, "fork electra is active"},
		{"activation in the past", func(p *ForkParameters) { p.Gloas = Fork{Version: [4]byte{9}, Epoch: 8} }, "at or before the current epoch 8"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fp := old
			tc.mutate(&fp)
			err := c.MigrateForkParameters(fp)
			urequire.ErrorContains(t, err, tc.err)
			urequire.True(t, c.ClientState.ForkParameters == old, "nothing changed")
		})
	}
}

// Future forks can be moved, but only in activation order.
func TestMigrateForkParametersOrder(t *testing.T) {
	c := migrateClient(t, 70)
	// Make Fulu a future fork (epoch 20) so two forks are free to move.
	cs := *c.ClientState
	cs.ForkParameters.Fulu.Epoch = 20
	c.ClientState = &cs
	bad := cs.ForkParameters
	bad.Gloas = Fork{Version: [4]byte{9}, Epoch: 15}
	urequire.ErrorContains(t, c.MigrateForkParameters(bad), "precedes fork fulu")
	good := cs.ForkParameters
	good.Fulu.Epoch = 10
	good.Gloas = Fork{Version: [4]byte{9}, Epoch: 15}
	urequire.NoError(t, c.MigrateForkParameters(good))
}

func TestMigrateForkParametersNeedsActiveClient(t *testing.T) {
	c := migrateClient(t, 70)
	cs := *c.ClientState
	cs.IsFrozen = true
	c.ClientState = &cs
	fp := cs.ForkParameters
	fp.Gloas = Fork{Version: [4]byte{9}, Epoch: 12}
	urequire.ErrorContains(t, c.MigrateForkParameters(fp), "status Frozen")
}

func TestForkParametersWire(t *testing.T) {
	p := fixtureNative().clientState.ForkParameters
	p.Gloas = Fork{Version: [4]byte{1, 2, 3, 4}, Epoch: 99}
	got, err := DecodeForkParameters(EncodeForkParameters(p))
	urequire.NoError(t, err)
	urequire.True(t, got == p, "round trip")

	bz := EncodeForkParameters(p)
	_, err = DecodeForkParameters(append(bz, 0))
	urequire.ErrorContains(t, err, "trailing")
	_, err = DecodeForkParameters(bz[:len(bz)-1])
	urequire.Error(t, err)
	// A 3-byte version is refused.
	bad := append([]byte{3, 1, 2, 3}, bz[5:]...)
	_, err = DecodeForkParameters(bad)
	urequire.ErrorContains(t, err, "4 bytes")
}
