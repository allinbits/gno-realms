package core

import (
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/p/aib/ibc/lightclient/tendermint/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/uassert/v0"
)

const (
	upgradeTestImplPath  = implPathPrefix + "vtest"
	upgradeTestImplPath2 = implPathPrefix + "vtest2"
)

// upgradeTestLogic is a stand-in implementation declared in this package to
// exercise the lifecycle plumbing. It records what it was installed over and
// keeps the Store it was built with, so a test can check that a swapped
// implementation shares the proxy-owned state. Only SendPacket is exercised;
// the other methods satisfy the interface.
type upgradeTestLogic struct {
	store           Store
	version         string
	installs        int
	prevPath        string
	prevVersion     string
	sendPacketCalls int
}

func newUpgradeTestLogic(s Store) Logic  { return &upgradeTestLogic{store: s, version: "vtest"} }
func newUpgradeTestLogic2(s Store) Logic { return &upgradeTestLogic{store: s, version: "vtest2"} }

func (l *upgradeTestLogic) Version() string { return l.version }

func (l *upgradeTestLogic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	l.installs++
	l.prevPath, l.prevVersion = prevPath, prevVersion
}

func (l *upgradeTestLogic) SendPacket(_ int, rlm realm, msg types.MsgSendPacket) uint64 {
	l.sendPacketCalls++
	return 42
}

func (l *upgradeTestLogic) CreateClient(_ int, rlm realm, relayer address, cs lightclient.ClientState, cons lightclient.ConsensusState) string {
	panic("upgradeTestLogic.CreateClient: not implemented")
}

func (l *upgradeTestLogic) RegisterCounterparty(_ int, rlm realm, clientID string, merklePrefix [][]byte, counterpartyClientID string) {
	panic("upgradeTestLogic.RegisterCounterparty: not implemented")
}

func (l *upgradeTestLogic) UpdateClient(_ int, rlm realm, clientID string, msg lightclient.ClientMessage) {
	panic("upgradeTestLogic.UpdateClient: not implemented")
}

func (l *upgradeTestLogic) UpgradeClient(_ int, rlm realm, clientID string, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState any) {
	panic("upgradeTestLogic.UpgradeClient: not implemented")
}

func (l *upgradeTestLogic) RecoverClient(_ int, rlm realm, subjectClientID, substituteClientID string) {
	panic("upgradeTestLogic.RecoverClient: not implemented")
}

func (l *upgradeTestLogic) RecvPacket(_ int, rlm realm, msg types.MsgRecvPacket) types.ResponseResultType {
	panic("upgradeTestLogic.RecvPacket: not implemented")
}

func (l *upgradeTestLogic) WriteAcknowledgement(_ int, rlm realm, clientID string, sequence uint64, ack types.Acknowledgement) {
	panic("upgradeTestLogic.WriteAcknowledgement: not implemented")
}

func (l *upgradeTestLogic) Acknowledgement(_ int, rlm realm, msg types.MsgAcknowledgement) types.ResponseResultType {
	panic("upgradeTestLogic.Acknowledgement: not implemented")
}

func (l *upgradeTestLogic) Timeout(_ int, rlm realm, msg types.MsgTimeout) types.ResponseResultType {
	panic("upgradeTestLogic.Timeout: not implemented")
}

// resetUpgradeState restores a fresh store, no implementation and an authority
// without members, as at genesis in the test framework. Every test here resets
// on entry and exit so a swapped implementation never leaks into other tests.
func resetUpgradeState() {
	store = newStore()
	impl = nil
	implPath = ""
	implVersion = ""
	implCtors = bptree.NewBPTree32()
	auth = authority.New("")
	relayers = bptree.NewBPTree32()
	paused = false
}

// registerAs registers ctor as if from the implementation realm at path.
func registerAs(cur realm, path string, ctor func(Store) Logic) {
	testing.SetRealm(testing.NewCodeRealm(path))
	RegisterImpl(cross(cur), ctor)
}

func TestRegisterImplRejectsForeignRealm(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	uassert.AbortsContains(t, cur, "is not under "+implPathPrefix, func() {
		registerAs(cur, "gno.land/r/evil/dao", newUpgradeTestLogic)
	})
	uassert.AbortsContains(t, cur, "is not under "+implPathPrefix, func() {
		registerAs(cur, corePkgPath+"/v1", newUpgradeTestLogic)
	})
	uassert.Equal(t, "", ImplPath())
}

func TestRegisterImplBootstrapsFirstOnly(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	// The first registration auto-activates: genesis needs no UpdateImpl.
	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
	uassert.Equal(t, "vtest", ImplVersion())
	tl := impl.(*upgradeTestLogic)
	uassert.Equal(t, 1, tl.installs)
	uassert.Equal(t, "", tl.prevPath)

	// A later registration only records a candidate.
	registerAs(cur, upgradeTestImplPath2, newUpgradeTestLogic2)
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
	uassert.Equal(t, 2, len(RegisteredImplPaths()))
}

func TestUpdateImplRejectsUnregisteredPath(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	AddAuthorityMember(cross(cur), cur.Address())
	uassert.AbortsContains(t, cur, "no implementation registered at "+upgradeTestImplPath, func() {
		UpdateImpl(cross(cur), upgradeTestImplPath)
	})
}

func TestUpdateImplRequiresAuthority(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	registerAs(cur, upgradeTestImplPath2, newUpgradeTestLogic2)

	// This realm is not a member of the authority.
	uassert.AbortsContains(t, cur, "is not a member of the authority", func() {
		UpdateImpl(cross(cur), upgradeTestImplPath2)
	})
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
}

// TestUpdateImplSwapsDispatchAndSharesStore proves the swap plumbing: the entry
// point routes to the newly activated implementation, that implementation is
// handed the same proxy-owned store (state is shared, not copied), OnInstall
// sees what it replaces, and the rollback is a plain UpdateImpl.
func TestUpdateImplSwapsDispatchAndSharesStore(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	seeded := store.addClient(lightclient.Tendermint, address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"), tendermint.NewTMLightClient())

	registerAs(cur, upgradeTestImplPath2, newUpgradeTestLogic2)
	AddAuthorityMember(cross(cur), cur.Address())
	UpdateImpl(cross(cur), upgradeTestImplPath2)

	uassert.Equal(t, upgradeTestImplPath2, ImplPath())
	uassert.Equal(t, "vtest2", ImplVersion())
	uassert.Equal(t, uint64(42), SendPacket(cross(cur), types.MsgSendPacket{}))

	tl, ok := impl.(*upgradeTestLogic)
	if !ok {
		t.Fatal("active implementation is not *upgradeTestLogic after UpdateImpl")
	}
	uassert.Equal(t, 1, tl.sendPacketCalls)
	uassert.Equal(t, upgradeTestImplPath, tl.prevPath)
	uassert.Equal(t, "vtest", tl.prevVersion)
	uassert.True(t, tl.store.Client(seeded.id) != nil)

	// Rollback.
	UpdateImpl(cross(cur), upgradeTestImplPath)
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
	uassert.True(t, store.getClient(seeded.id) != nil)
}

func TestUpdateImplAbortsWhenOnInstallPanics(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	registerAs(cur, upgradeTestImplPath2, func(s Store) Logic { return &panickingLogic{} })
	AddAuthorityMember(cross(cur), cur.Address())

	uassert.AbortsContains(t, cur, "migration failed", func() {
		UpdateImpl(cross(cur), upgradeTestImplPath2)
	})
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
}

type panickingLogic struct{ upgradeTestLogic }

func (*panickingLogic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	panic("migration failed")
}

// captureRealm returns the cur of a crossing frame that has ended by the time
// the caller looks at it: a realm value that is not current anymore.
func captureRealm(cur realm) realm { return cur }

func TestGatesRejectStaleRealm(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	stale := captureRealm(cross(cur))
	c := store.addClient(lightclient.Tendermint, address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"), tendermint.NewTMLightClient())

	uassert.PanicsContains(t, cur, "access denied", func() {
		c.SetPacketReceipt(0, stale, 1)
	})
	uassert.False(t, c.HasPacketReceipt(1))
	uassert.PanicsContains(t, cur, "access denied", func() {
		store.AddClient(0, stale, lightclient.Tendermint, address(""), tendermint.NewLightClient)
	})
	uassert.PanicsContains(t, cur, "access denied", func() {
		EmitSendPacket(0, stale, types.Packet{})
	})
	// The live cur passes.
	c.SetPacketReceipt(0, cur, 1)
	uassert.True(t, c.HasPacketReceipt(1))
}
