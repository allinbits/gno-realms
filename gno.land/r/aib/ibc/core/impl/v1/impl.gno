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
	"errors"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
)

const version = "v1"

// MigrationEthereumForkSchedule replaces the fork schedule of an Ethereum
// client (ethereum.EthLightClient.MigrateForkParameters); params is
// ethereum.EncodeForkParameters of the new schedule.
const MigrationEthereumForkSchedule = "ethereum-fork-schedule"

// MigrationEthereumVerifier replaces an Ethereum client's verifier by a
// verifier version registered with core.RegisterVerifier; params is the
// registration's realm path. The conversion keeps the client's id, client
// state, consensus states and packet state; it runs only here, at the
// governed installation.
const MigrationEthereumVerifier = "ethereum-verifier"

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
// forkMigrator is a verifier whose fork schedule a governed migration can
// change: ethereum/v0's verifier, and any later version that embeds it or
// implements the same.
type forkMigrator interface {
	CheckForkParameters(fp ethereum.ForkParameters) error
	MigrateForkParameters(fp ethereum.ForkParameters) error
}

func (l *logic) migration(clientID, migration string, params []byte) (forkMigrator, ethereum.ForkParameters, error) {
	c := l.store.Client(clientID)
	if c == nil {
		return nil, ethereum.ForkParameters{}, ufmt.Errorf("client %s not found", clientID)
	}
	if migration != MigrationEthereumForkSchedule {
		return nil, ethereum.ForkParameters{}, ufmt.Errorf("unknown client migration %q", migration)
	}
	if c.Type() != ethereum.ClientType {
		return nil, ethereum.ForkParameters{}, ufmt.Errorf("client %s is not an Ethereum client", clientID)
	}
	lc, ok := c.LightClient().(forkMigrator)
	if !ok {
		return nil, ethereum.ForkParameters{}, ufmt.Errorf("client %s's verifier (%s) does not support a fork-schedule migration", clientID, core.VerifierVersion(clientID))
	}
	fp, err := ethereum.DecodeForkParameters(params)
	if err != nil {
		return nil, ethereum.ForkParameters{}, err
	}
	return lc, fp, nil
}

// CheckMigrateClient is why MigrateClient would fail now, or nil, with no
// change (core.ClientMigrationChecker). A verifier replacement is checked from
// its registration's declared values and the client's state alone: no
// conversion runs.
func (l *logic) CheckMigrateClient(clientID, migration string, params []byte) error {
	if migration == MigrationEthereumVerifier {
		if r := core.CheckVerifierReplacement(clientID, string(params)); r != "" {
			return errors.New(r)
		}
		return nil
	}
	lc, fp, err := l.migration(clientID, migration, params)
	if err != nil {
		return err
	}
	return lc.CheckForkParameters(fp)
}

// MigrateClient implements core.ClientMigrator: a refusal is returned with
// nothing changed, so the governed decision is spent.
func (l *logic) MigrateClient(_ int, rlm realm, clientID, migration string, params []byte) error {
	if migration == MigrationEthereumVerifier {
		return l.replaceVerifier(0, rlm, clientID, string(params))
	}
	lc, fp, err := l.migration(clientID, migration, params)
	if err != nil {
		return err
	}
	// MigrateForkParameters checks before it writes: a refusal changes
	// nothing. lc is the proxy's verifier: the /p/ method writes under the
	// proxy.
	if err := lc.MigrateForkParameters(fp); err != nil {
		return err
	}
	core.EmitMigrateClient(0, rlm, clientID, ethereum.ClientType, migration)
	return nil
}

// replaceVerifier installs the verifier version registered at path on
// clientID. The conversion runs on a detached snapshot of the live verifier
// (its panic recovered as a refusal), and the result must name the
// registered version, be Active and keep the latest height, so every
// consensus state the client trusted stays; only then is it installed. Any
// failure is returned with nothing changed.
func (l *logic) replaceVerifier(_ int, rlm realm, clientID, path string) error {
	if r := core.CheckVerifierReplacement(clientID, path); r != "" {
		return errors.New(r)
	}
	convert, want, _ := core.VerifierConversion(path)
	c := l.store.Client(clientID)
	live := c.LightClient()
	snap := live.(core.SnapshotVerifier).Snapshot()
	cand, err := convertSnapshot(convert, snap)
	if err != nil {
		return err
	}
	got := ""
	if v, ok := cand.(core.VersionedVerifier); ok {
		got = v.VerifierVersion()
	}
	switch {
	case got != want:
		return errors.New("the converted verifier is " + got + ", not " + want)
	case cand.Status() != lightclient.Active:
		return ufmt.Errorf("the converted verifier is %s, not Active", cand.Status())
	case !cand.LatestHeight().EQ(live.LatestHeight()):
		return ufmt.Errorf("the converted verifier's latest height is %s, not %s", cand.LatestHeight(), live.LatestHeight())
	}
	c.SetLightClient(0, rlm, func(lightclient.Interface) lightclient.Interface { return cand })
	core.EmitMigrateClient(0, rlm, clientID, c.Type(), MigrationEthereumVerifier+" "+want)
	return nil
}

// convertSnapshot runs a registered conversion on a snapshot, a panic
// returned as a refusal.
func convertSnapshot(convert func(lightclient.Interface) lightclient.Interface, snap lightclient.Interface) (cand lightclient.Interface, err error) {
	defer func() {
		if r := recover(); r != nil {
			cand, err = nil, ufmt.Errorf("the conversion failed: %v", r)
		}
	}()
	cand = convert(snap)
	if cand == nil {
		return nil, errors.New("the conversion returned no verifier")
	}
	return cand, nil
}
