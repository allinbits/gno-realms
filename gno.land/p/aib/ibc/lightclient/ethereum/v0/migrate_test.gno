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

// migratedFrom is an Active client of the native fixture that applied its
// first update (finalized slot 128, epoch 16; signature slot 145, epoch 18),
// with the block time set to the slot given.
func migratedFrom(t *testing.T, slot uint64) *EthLightClient {
	f := fixtureNative()
	c := applied(t, f, 1)
	cs := c.ClientState
	setNow(cs.GenesisTime + (slot-cs.GenesisSlot)*cs.SecondsPerSlot)
	urequire.Equal(t, "Active", string(c.Status()))
	return c
}

// A migration keeps every fork the client verified updates under (epochs 16
// to 18 here) and passes a created client's checks.
func TestMigrateForkParametersRefusals(t *testing.T) {
	c := migratedFrom(t, 200) // the clock at epoch 25
	old := c.ClientState.ForkParameters
	cases := []struct {
		name   string
		mutate func(p *ForkParameters)
		err    string
	}{
		{"unchanged", func(p *ForkParameters) {}, "unchanged"},
		{"genesis version", func(p *ForkParameters) { p.GenesisForkVersion[0]++ }, "genesis"},
		{"genesis slot", func(p *ForkParameters) { p.GenesisSlot++ }, "genesis"},
		{"verified fork epoch", func(p *ForkParameters) { p.Fulu.Epoch = 17 }, "a fork the client verified updates under (epochs 16 to 18)"},
		{"verified fork version", func(p *ForkParameters) { p.Fulu.Version[3]++ }, "a fork the client verified updates under"},
		{"fork inside the verified range", func(p *ForkParameters) { p.Gloas = Fork{Version: [4]byte{9}, Epoch: 17} }, "a fork the client verified updates under"},
		{"fork without a version", func(p *ForkParameters) { p.Gloas = Fork{Epoch: 30} }, "gloas fork is scheduled at epoch 30 without a version"},
		{"electra after the latest slot", func(p *ForkParameters) {
			p.Electra.Epoch = 20
			p.Fulu.Epoch = 20
		}, "is before Electra"},
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

// Forks the client verified nothing under may change: one that activated
// after its last verified epoch, even before the block time (a migration
// that lands after the fork it schedules), and one superseded before its
// first. A client that applied no update may take any valid schedule.
func TestMigrateForkParametersOutsideVerifiedRange(t *testing.T) {
	c := migratedFrom(t, 200)
	fp := c.ClientState.ForkParameters
	fp.Gloas = Fork{Version: [4]byte{9}, Epoch: 20} // before the clock's epoch 25
	urequire.NoError(t, c.MigrateForkParameters(fp))
	fp.Electra.Version[0]++ // superseded by Fulu at epoch 1
	urequire.NoError(t, c.MigrateForkParameters(fp))

	fresh := migrateClient(t, 70)
	fp = fresh.ClientState.ForkParameters
	fp.Fulu.Version[0]++ // active since epoch 1, before the bootstrap at epoch 8
	urequire.NoError(t, fresh.MigrateForkParameters(fp))
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
	urequire.ErrorContains(t, c.MigrateForkParameters(bad), "gloas fork epoch 15 precedes the previous fork's 20")
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

// A verifier replacement's result is held to the checks of a created or
// recovered client: the same chain and router, the retired verifier's record
// of what it verified, and a valid schedule keeping every fork it verified
// updates under (epochs 16 to 18 here), other forks free.
func TestCheckSuccessor(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(next *EthLightClient, cs *ClientState)
		err    string
	}{
		{"unchanged", func(*EthLightClient, *ClientState) {}, ""},
		{"later fork scheduled", func(_ *EthLightClient, cs *ClientState) {
			cs.ForkParameters.Gloas = Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 20}
		}, ""},
		{"later fork without a version", func(_ *EthLightClient, cs *ClientState) { cs.ForkParameters.Gloas = Fork{Epoch: 20} }, "gloas fork is scheduled at epoch 20 without a version"},
		{"verified fork rewritten", func(_ *EthLightClient, cs *ClientState) { cs.ForkParameters.Fulu.Version[0]++ }, "changes a fork the retired verifier verified updates under"},
		{"fork scheduled inside the verified range", func(_ *EthLightClient, cs *ClientState) {
			cs.ForkParameters.Gloas = Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 17}
		}, "changes a fork the retired verifier verified updates under"},
		{"router rewritten", func(_ *EthLightClient, cs *ClientState) { cs.IBCContractAddress = flip(cs.IBCContractAddress, 0) }, "different chain or router"},
		{"commitment slot rewritten", func(_ *EthLightClient, cs *ClientState) { cs.IBCCommitmentSlot = flip(cs.IBCCommitmentSlot, 0) }, "different chain or router"},
		{"chain id rewritten", func(_ *EthLightClient, cs *ClientState) { cs.ChainID++ }, "different chain or router"},
		{"slots per epoch rewritten", func(_ *EthLightClient, cs *ClientState) { cs.SlotsPerEpoch *= 2 }, "different chain or router"},
		{"verified range dropped", func(next *EthLightClient, _ *ClientState) { next.verified = false }, "does not carry what the retired verifier verified"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := migratedFrom(t, 150)
			r := Retire(c)
			next := NewFrom(r)
			cs := *next.ClientState
			tc.mutate(next, &cs)
			next.ClientState = &cs
			err := r.CheckSuccessor(next)
			if tc.err == "" {
				urequire.NoError(t, err)
				return
			}
			urequire.ErrorContains(t, err, tc.err)
		})
	}
}
