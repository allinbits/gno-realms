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
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
)

const version = "v1"

// MigrationEthereumForkSchedule replaces the fork schedule of an Ethereum
// client (ethereum.EthLightClient.MigrateForkParameters); params is
// ethereum.EncodeForkParameters of the new schedule.
const MigrationEthereumForkSchedule = "ethereum-fork-schedule"

// MigrationEthereumVerifier replaces an Ethereum client's verifier by
// another verifier version; params is the target version. Only a conversion
// this implementation compiles in, declared as plain values (from, to), is
// run: none in impl/v1 itself; a later implementation declares its own
// (NewWithConversions), installed by a governed, manifest-checked upgrade.
// The conversion keeps the client's id, its consensus states (the new
// verifier serves the retired one's, read only) and its packet state.
const MigrationEthereumVerifier = "ethereum-verifier"

type logic struct {
	core.Logic // impl/v0's lifecycle
	store      core.Store
	ver        string

	// The verifier conversions this implementation compiles in: the i-th
	// converts version convFrom[i] to convTo[i].
	convFrom, convTo []string
	convert          []func(*ethereum.Retired) lightclient.Interface
}

var (
	_ core.Logic                  = (*logic)(nil)
	_ core.ClientMigrator         = (*logic)(nil)
	_ core.ClientMigrationChecker = (*logic)(nil)
)

// New builds the implementation against the proxy's store.
func New(s core.Store) core.Logic {
	return &logic{Logic: implv0.New(s), store: s, ver: version}
}

// NewWithConversions is impl/v1's logic under version ver with verifier
// conversions compiled in, the i-th from verifier version from[i] to version
// to[i] (the three slices of one length): the constructor of a later core
// implementation that brings new verifier versions, registered under its own
// path and installed by a governed upgrade. Each convert[i] must be a
// function of the new verifier's /p/ package; it receives a read-only view
// of the live verifier (ethereum.Retired), so it cannot write to it, and
// returns the new one.
func NewWithConversions(s core.Store, ver string, from, to []string, convert []func(*ethereum.Retired) lightclient.Interface) core.Logic {
	if len(from) != len(to) || len(to) != len(convert) {
		panic("NewWithConversions: from, to and convert differ in length")
	}
	l := &logic{Logic: implv0.New(s), store: s, ver: ver}
	l.convFrom = append(l.convFrom, from...)
	l.convTo = append(l.convTo, to...)
	l.convert = append(l.convert, convert...)
	return l
}

// conversion is the conversion of from to to this implementation compiles
// in, or nil.
func (l *logic) conversion(from, to string) func(*ethereum.Retired) lightclient.Interface {
	for i := range l.convFrom {
		if l.convFrom[i] == from && l.convTo[i] == to {
			return l.convert[i]
		}
	}
	return nil
}

func init(cur realm) {
	core.RegisterImpl(cross(cur), New, version, []string{"", "v0"}) // as CheckInstall
}

func (l *logic) Version() string {
	return l.ver
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
	case "", "v0", version, l.ver:
		return nil
	}
	return ufmt.Errorf("core impl %s cannot install over version %s", version, prevVersion)
}

// forkMigrator is a verifier whose fork schedule a governed migration can
// change: ethereum/v0's verifier, and any later version that embeds it or
// implements the same.
type forkMigrator interface {
	CheckForkParameters(fp ethereum.ForkParameters) error
	MigrateForkParameters(fp ethereum.ForkParameters) error
}

// migration resolves a migration's subject and parameters, or why it cannot
// apply.
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
		return l.checkConversion(clientID, string(params))
	}
	lc, fp, err := l.migration(clientID, migration, params)
	if err != nil {
		return err
	}
	return lc.CheckForkParameters(fp)
}

// MigrateClient implements core.ClientMigrator. The proxy has checked that
// ibcgov decided it and that the client is not retired. A refusal is
// returned with nothing changed, so the governed decision is spent.
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

// checkConversion is why clientID's verifier cannot be converted to version
// to now, or nil, from plain values alone (this implementation's declared
// conversion, the client's type, status and verifier version): nothing is
// converted.
func (l *logic) checkConversion(clientID, to string) error {
	c := l.store.Client(clientID)
	switch {
	case c == nil:
		return ufmt.Errorf("client %s not found", clientID)
	case c.Type() != ethereum.ClientType:
		return ufmt.Errorf("client %s is not an Ethereum client", clientID)
	}
	from := core.VerifierVersion(clientID)
	if l.conversion(from, to) == nil {
		return ufmt.Errorf("core impl %s converts no %s verifier to %s", l.ver, from, to)
	}
	// An Expired client is converted too, keeping its status (ADR pr6375
	// R16): a fork or a verifier defect may stop its updates long enough for
	// it to expire before the conversion lands, and an ordinary governed
	// recovery then follows. A Frozen client is not: its misbehaviour is
	// resolved by a recovery first.
	if st := c.LightClient().Status(); st != lightclient.Active && st != lightclient.Expired {
		return ufmt.Errorf("client %s is %s, not Active or Expired", clientID, st)
	}
	// The conversion reads the live verifier through its ethereum/v0 state:
	// a verifier keeping its state otherwise needs migration support of its
	// own.
	if _, ok := c.LightClient().(ethState); !ok {
		return ufmt.Errorf("client %s's verifier (%s) exposes no ethereum/v0 state to convert", clientID, from)
	}
	return nil
}

// replaceVerifier converts clientID's verifier to version to with this
// implementation's conversion and installs the result. The conversion and
// every check on its result (it names version to, keeps the live verifier's
// status, Active or Expired, and its latest height and, for a verifier
// exposing ethereum/v0 state, the slot from which it trusts consensus states
// and every fork active at that height, its schedule valid)
// run inside one recovered boundary in the core's realm: a
// panic or a mismatch is a refusal, with nothing changed. Only then is the
// new verifier installed.
func (l *logic) replaceVerifier(_ int, rlm realm, clientID, to string) error {
	if err := l.checkConversion(clientID, to); err != nil {
		return err
	}
	c := l.store.Client(clientID)
	live := c.LightClient()
	es, ok := live.(ethState)
	if !ok {
		return ufmt.Errorf("client %s's verifier keeps no ethereum/v0 state to convert", clientID)
	}
	// The conversion sees the live verifier only through a read-only view.
	cand, err := convertAndCheck(l.conversion(core.VerifierVersion(clientID), to), ethereum.Retire(es.Ethereum()), to, live.Status(), live.LatestHeight(), es.Ethereum().TrustedFromSlot)
	if err != nil {
		return err
	}
	c.SetLightClient(0, rlm, func(lightclient.Interface) lightclient.Interface { return cand })
	core.EmitMigrateClient(0, rlm, clientID, c.Type(), MigrationEthereumVerifier+" "+to)
	return nil
}

// ethState is a verifier exposing ethereum/v0 state: the v0 verifier, or a
// later version wrapping it.
type ethState interface {
	Ethereum() *ethereum.EthLightClient
}

// convertAndCheck runs the conversion on a read-only view of the live
// verifier and checks the result, any panic on the way returned as a
// refusal: the view gives the conversion nothing to write with, so a
// refused conversion leaves nothing half-written.
func convertAndCheck(convert func(*ethereum.Retired) lightclient.Interface, view *ethereum.Retired, want string, status lightclient.Status, height types.Height, trustedFrom uint64) (cand lightclient.Interface, err error) {
	defer func() {
		if r := recover(); r != nil {
			cand, err = nil, ufmt.Errorf("the converted verifier failed its checks: %v", r)
		}
	}()
	cand = convert(view)
	if cand == nil {
		return nil, errors.New("the conversion returned no verifier")
	}
	v, ok := cand.(core.VersionedVerifier)
	if !ok || v.VerifierVersion() != want {
		got := ""
		if ok {
			got = v.VerifierVersion()
		}
		return nil, errors.New("the converted verifier is " + got + ", not " + want)
	}
	if st := cand.Status(); st != status {
		return nil, ufmt.Errorf("the converted verifier is %s, not %s", st, status)
	}
	if h := cand.LatestHeight(); !h.EQ(height) {
		return nil, ufmt.Errorf("the converted verifier's latest height is %s, not %s", h, height)
	}
	if es, ok := cand.(ethState); ok {
		if es.Ethereum().TrustedFromSlot != trustedFrom {
			return nil, ufmt.Errorf("the converted verifier trusts consensus states from slot %d, not %d", es.Ethereum().TrustedFromSlot, trustedFrom)
		}
		// Its fork schedule is checked as a created client's is, and keeps
		// every fork the live verifier has verified under.
		if err := view.CheckSuccessor(es.Ethereum()); err != nil {
			return nil, ufmt.Errorf("the converted verifier's fork schedule: %v", err)
		}
	}
	return cand, nil
}
