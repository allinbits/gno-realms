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
// before an Ethereum fork that this package version already verifies (its
// containers and generalized indices are known here, only the activation
// epoch was not). A fork whose containers change needs a new package version
// and a conversion through the core's Client.SetLightClient instead.
//
// The new schedule may only change forks that are not active yet: every fork
// whose epoch is at or before the current epoch (the later of the latest
// trusted slot's and the block time's) must be unchanged, version and epoch,
// and every changed fork must activate after the current epoch. The genesis
// fork version and slot never change, the fork epochs stay in order, and the
// schedule must differ from the current one. The client must be Active.
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
	current := cs.LatestSlot
	if s, err := c.currentSlot(); err == nil && s > current {
		current = s
	}
	epoch := cs.epochAtSlot(current)
	olds, news := old.forks(), fp.forks()
	for i := range olds {
		o, n := olds[i], news[i]
		if o.Epoch <= epoch {
			if n != o {
				return ufmt.Errorf("fork %s is active since epoch %d and cannot change", forkNames[i], o.Epoch)
			}
			continue
		}
		if n != o && n.Epoch <= epoch {
			return ufmt.Errorf("fork %s cannot activate at epoch %d, at or before the current epoch %d", forkNames[i], n.Epoch, epoch)
		}
		if i > 0 && n.Epoch < news[i-1].Epoch {
			return ufmt.Errorf("fork %s at epoch %d precedes fork %s at epoch %d", forkNames[i], n.Epoch, forkNames[i-1], news[i-1].Epoch)
		}
	}
	return nil
}

var forkNames = []string{"altair", "bellatrix", "capella", "deneb", "electra", "fulu", "gloas"}

// forks lists the forks in activation order.
func (p ForkParameters) forks() []Fork {
	return []Fork{p.Altair, p.Bellatrix, p.Capella, p.Deneb, p.Electra, p.Fulu, p.Gloas}
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
