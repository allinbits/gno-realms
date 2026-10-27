package ethereum

import (
	"errors"

	"gno.land/p/aib/encoding/wire/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/nt/ufmt/v0"
)

// MigrateForkParameters replaces the fork schedule of a live client in place,
// keeping its client state otherwise, its consensus states and (in the IBC
// core) its client id and packet state: the migration R16 of ADR pr6375 needs
// for an Ethereum fork that this package version already verifies (its
// containers and generalized indices are known here, only the activation
// epoch was not). A fork whose containers change needs a new package version
// and a conversion through the core's Client.SetLightClient instead.
//
// The new schedule must keep every fork the client verified signed updates
// under (keepsVerifiedForks, the rule a recovery and a verifier replacement
// follow too), pass ValidateBasic's checks (epochs in order, a version for
// every scheduled fork, Electra at or before the latest slot), keep the
// genesis fork version and slot, and differ from the current one. The client
// must be Active. A fork that activated after the last epoch the client
// verified may still be scheduled: a migration that lands after the fork,
// while the client stalls before it, repairs it without waiting for expiry.
//
// Call it on the stored client (the core's verifier): it writes the new state
// under the receiver's storage realm.
func (c *EthLightClient) MigrateForkParameters(fp ForkParameters) error {
	if err := c.CheckForkParameters(fp); err != nil {
		return err
	}
	updated := *c.ClientState
	updated.ForkParameters = fp
	c.ClientState = &updated
	return nil
}

// CheckForkParameters is why MigrateForkParameters would refuse fp, or nil;
// it changes nothing, so a governed migration is refused deterministically
// before it runs.
func (c *EthLightClient) CheckForkParameters(fp ForkParameters) error {
	if status := c.Status(); status != lightclient.Active {
		return ufmt.Errorf("cannot migrate a client with status %s", status)
	}
	cs := c.ClientState
	old := cs.ForkParameters
	if fp == old {
		return errors.New("the fork schedule is unchanged")
	}
	if fp.GenesisForkVersion != old.GenesisForkVersion || fp.GenesisSlot != old.GenesisSlot {
		return errors.New("the genesis fork version and slot cannot change")
	}
	if err := fp.validate(); err != nil {
		return err
	}
	next := *cs
	next.ForkParameters = fp
	if err := next.verifySupportedFork(next.LatestSlot); err != nil {
		return err
	}
	if !c.keepsVerifiedForks(fp) {
		return ufmt.Errorf("the schedule changes a fork the client verified updates under (epochs %d to %d)",
			cs.epochAtSlot(c.verifiedFrom), cs.epochAtSlot(c.verifiedTo))
	}
	return nil
}

// CheckSuccessor is why next cannot take over from the verifier r views in a
// verifier replacement, or nil. A conversion is code of a later core
// implementation: nothing else holds its result to the checks a created or
// recovered client meets, so they are made here. next must track the same
// chain and router (sameChainAndRouter, which RouteIdentity summarizes),
// carry the retired verifier's record of what it verified, and have a valid
// fork schedule keeping every fork the retired verifier verified updates
// under (keepsVerifiedForks), as a recovery must.
func (r *Retired) CheckSuccessor(next *EthLightClient) error {
	old, cs := r.c.ClientState, next.ClientState
	if !sameChainAndRouter(old, cs) {
		return errors.New("the successor tracks a different chain or router")
	}
	if next.verified != r.c.verified || next.verifiedFrom != r.c.verifiedFrom || next.verifiedTo != r.c.verifiedTo {
		return errors.New("the successor does not carry what the retired verifier verified")
	}
	if err := cs.ForkParameters.validate(); err != nil {
		return err
	}
	if err := cs.verifySupportedFork(cs.LatestSlot); err != nil {
		return err
	}
	if !r.c.keepsVerifiedForks(cs.ForkParameters) {
		return errors.New("the successor changes a fork the retired verifier verified updates under")
	}
	return nil
}

// EncodeForkParameters writes p in the wire format: Blob(genesis fork
// version, 4 bytes), Uint genesis slot, then for each fork from Altair to
// Gloas Blob(version, 4 bytes) and Uint epoch.
func EncodeForkParameters(p ForkParameters) []byte {
	w := wire.NewWriter()
	w.Blob(p.GenesisForkVersion[:]).Uint(p.GenesisSlot)
	for _, f := range p.forks() {
		w.Blob(f.Version[:]).Uint(f.Epoch)
	}
	return w.Bytes()
}

// DecodeForkParameters reads what EncodeForkParameters writes, refusing
// trailing bytes.
func DecodeForkParameters(bz []byte) (ForkParameters, error) {
	d := newDecoder(bz)
	p := ForkParameters{GenesisForkVersion: d.version(), GenesisSlot: d.Uint()}
	fork := func() Fork { return Fork{Version: d.version(), Epoch: d.Uint()} }
	p.Altair = fork()
	p.Bellatrix = fork()
	p.Capella = fork()
	p.Deneb = fork()
	p.Electra = fork()
	p.Fulu = fork()
	p.Gloas = fork()
	if err := d.done(); err != nil {
		return ForkParameters{}, ufmt.Errorf("fork parameters: %v", err)
	}
	return p, nil
}

// version reads a 4-byte fork version blob.
func (d *decoder) version() [4]byte {
	var v [4]byte
	b := d.Blob()
	if d.ok() && len(b) != 4 {
		d.err = errors.New("wire: a fork version is 4 bytes")
	}
	copy(v[:], b)
	return v
}
