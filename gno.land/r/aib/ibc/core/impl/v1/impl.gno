// Package impl is the second implementation of the IBC core lifecycle, behind
// the gno.land/r/aib/ibc/core proxy (see docs/adrs/0001). It runs impl/v0's
// lifecycle unchanged and adds core.ClientMigrator (ADR pr6375 R16): a
// governed migration of a live client's verifier that keeps its id, its
// consensus states and its packet state. Like v0 it holds no state of its own
// and is always invoked non-crossing by the proxy, as the proxy.
//
// It is activated by an UpdateImpl decision of gno.land/r/aib/ibc/ibcgov.
package impl

import (
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
)

const version = "v1"

// MigrationEthereumForkSchedule replaces the fork schedule of an Ethereum
// client (ethereum.EthLightClient.MigrateForkParameters); params is
// ethereum.EncodeForkParameters of the new schedule.
const MigrationEthereumForkSchedule = "ethereum-fork-schedule"

type logic struct {
	core.Logic // impl/v0's lifecycle
	store      core.Store
}

var (
	_ core.Logic                  = (*logic)(nil)
	_ core.ClientMigrator         = (*logic)(nil)
	_ core.ClientMigrationChecker = (*logic)(nil)
)

// New builds the implementation against the proxy's store.
func New(s core.Store) core.Logic {
	return &logic{Logic: implv0.New(s), store: s}
}

func init(cur realm) {
	core.RegisterImpl(cross(cur), New, version, []string{"", "v0"}) // as CheckInstall
}

func (l *logic) Version() string {
	return version
}

// OnInstall has nothing to migrate: v1 keeps v0's store layout. It installs
// over v0 or nothing (bootstrap), and re-installs over itself; anything else
// is refused.
func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	if err := l.CheckInstall(prevPath, prevVersion); err != nil {
		panic(err)
	}
}

// CheckInstall is why v1 refuses to install: it installs over v0, nothing or
// itself, as its manifest declares.
func (l *logic) CheckInstall(prevPath, prevVersion string) error {
	switch prevVersion {
	case "", "v0", version:
		return nil
	}
	return ufmt.Errorf("core impl %s cannot install over version %s", version, prevVersion)
}

// MigrateClient implements core.ClientMigrator. The proxy has checked that
// ibcgov decided it and that the client is not retired.
// migration resolves a migration's subject and parameters, or why it cannot
// apply.
func (l *logic) migration(clientID, migration string, params []byte) (*ethereum.EthLightClient, ethereum.ForkParameters, error) {
	c := l.store.Client(clientID)
	if c == nil {
		return nil, ethereum.ForkParameters{}, ufmt.Errorf("client %s not found", clientID)
	}
	if migration != MigrationEthereumForkSchedule {
		return nil, ethereum.ForkParameters{}, ufmt.Errorf("unknown client migration %q", migration)
	}
	lc, ok := c.LightClient().(*ethereum.EthLightClient)
	if !ok || c.Type() != ethereum.ClientType {
		return nil, ethereum.ForkParameters{}, ufmt.Errorf("client %s is not an Ethereum client", clientID)
	}
	fp, err := ethereum.DecodeForkParameters(params)
	if err != nil {
		return nil, ethereum.ForkParameters{}, err
	}
	return lc, fp, nil
}

// CheckMigrateClient is why MigrateClient would fail now, or nil, with no
// change (core.ClientMigrationChecker).
func (l *logic) CheckMigrateClient(clientID, migration string, params []byte) error {
	lc, fp, err := l.migration(clientID, migration, params)
	if err != nil {
		return err
	}
	return lc.CheckForkParameters(fp)
}

func (l *logic) MigrateClient(_ int, rlm realm, clientID, migration string, params []byte) {
	lc, fp, err := l.migration(clientID, migration, params)
	if err != nil {
		panic(err)
	}
	// lc is the proxy's verifier: the /p/ method writes under the proxy.
	if err := lc.MigrateForkParameters(fp); err != nil {
		panic(err)
	}
	core.EmitMigrateClient(0, rlm, clientID, ethereum.ClientType, migration)
}
