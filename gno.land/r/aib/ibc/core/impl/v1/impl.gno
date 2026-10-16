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
	_ core.Logic          = (*logic)(nil)
	_ core.ClientMigrator = (*logic)(nil)
)

// New builds the implementation against the proxy's store.
func New(s core.Store) core.Logic {
	return &logic{Logic: implv0.New(s), store: s}
}

func init(cur realm) {
	core.RegisterImpl(cross(cur), New)
}

func (l *logic) Version() string {
	return version
}

// OnInstall has nothing to migrate: v1 keeps v0's store layout. It installs
// over v0 or nothing (bootstrap), and re-installs over itself; anything else
// is refused.
func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	switch prevVersion {
	case "", "v0", version:
		return
	}
	panic(ufmt.Sprintf("core impl %s cannot install over version %s", version, prevVersion))
}

// MigrateClient implements core.ClientMigrator. The proxy has checked that
// ibcgov decided it and that the client is not retired.
func (l *logic) MigrateClient(_ int, rlm realm, clientID, migration string, params []byte) {
	c := l.store.Client(clientID)
	if c == nil {
		panic(ufmt.Sprintf("client %s not found", clientID))
	}
	switch migration {
	case MigrationEthereumForkSchedule:
		lc, ok := c.LightClient().(*ethereum.EthLightClient)
		if !ok || c.Type() != ethereum.ClientType {
			panic(ufmt.Sprintf("client %s is not an Ethereum client", clientID))
		}
		fp, err := ethereum.DecodeForkParameters(params)
		if err != nil {
			panic(err)
		}
		// lc is the proxy's verifier: the /p/ method writes under the proxy.
		if err := lc.MigrateForkParameters(fp); err != nil {
			panic(err)
		}
	default:
		panic(ufmt.Sprintf("unknown client migration %q", migration))
	}
	core.EmitMigrateClient(0, rlm, clientID, c.Type(), migration)
}
