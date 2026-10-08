package transfer

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/uassert/v0"
)

const (
	upgradeTestImplPath  = implPathPrefix + "vtest"
	upgradeTestImplPath2 = implPathPrefix + "vtest2"
)

// upgradeTestLogic is a stand-in implementation declared in this package to
// exercise the lifecycle plumbing; see r/aib/ibc/core/proxy_test.gno.
type upgradeTestLogic struct {
	store       Store
	version     string
	installs    int
	prevPath    string
	prevVersion string
	sendCalls   int
}

func newUpgradeTestLogic(s Store) Logic  { return &upgradeTestLogic{store: s, version: "vtest"} }
func newUpgradeTestLogic2(s Store) Logic { return &upgradeTestLogic{store: s, version: "vtest2"} }

func (l *upgradeTestLogic) Version() string { return l.version }

func (l *upgradeTestLogic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	l.installs++
	l.prevPath, l.prevVersion = prevPath, prevVersion
}

func (l *upgradeTestLogic) Render(path string) string {
	return "rendered by " + l.version + ": " + path
}

func (l *upgradeTestLogic) Transfer(_ int, rlm realm, sent []chain.Coin, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (types.MsgSendPacket, uint64) {
	panic("upgradeTestLogic.Transfer: not implemented")
}

func (l *upgradeTestLogic) OnSendPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	l.sendCalls++
	return nil
}

func (l *upgradeTestLogic) OnRecvPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult {
	panic("upgradeTestLogic.OnRecvPacket: not implemented")
}

func (l *upgradeTestLogic) OnTimeoutPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	panic("upgradeTestLogic.OnTimeoutPacket: not implemented")
}

func (l *upgradeTestLogic) OnAcknowledgementPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, acknowledgement []byte, payload types.Payload) error {
	panic("upgradeTestLogic.OnAcknowledgementPacket: not implemented")
}

// resetUpgradeState restores an empty store, no implementation and an
// authority without members, as at genesis in the test framework.
func resetUpgradeState() {
	denoms = bptree.NewBPTree32()
	totalEscrow = bptree.NewBPTree32()
	voucherTokens = bptree.NewBPTree32()
	clearPendingSends()
	impl = nil
	implPath = ""
	implVersion = ""
	implCtors = bptree.NewBPTree32()
	auth = authority.New("")
	blocked = bptree.NewBPTree32()
}

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
	uassert.Equal(t, "", ImplPath())
}

func TestRegisterImplBootstrapsFirstOnly(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
	uassert.Equal(t, "vtest", ImplVersion())
	registerAs(cur, upgradeTestImplPath2, newUpgradeTestLogic2)
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
	uassert.Equal(t, 2, len(RegisteredImplPaths()))
}

func TestUpdateImplRequiresAuthority(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	registerAs(cur, upgradeTestImplPath2, newUpgradeTestLogic2)
	uassert.AbortsContains(t, cur, "is not a member of the authority", func() {
		UpdateImpl(cross(cur), upgradeTestImplPath2)
	})
	AddAuthorityMember(cross(cur), cur.Address())
	uassert.AbortsContains(t, cur, "no implementation registered at", func() {
		UpdateImpl(cross(cur), implPathPrefix+"nowhere")
	})
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
}

// TestUpdateImplSwapsDispatchAndSharesStore: the newly activated
// implementation is handed the same proxy-owned store, and rollback is a plain
// UpdateImpl.
func TestUpdateImplSwapsDispatchAndSharesStore(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	d := ics20.NewDenom("uatom", ics20.NewHop(PortID, "07-tendermint-1"))
	setDenom(d)

	registerAs(cur, upgradeTestImplPath2, newUpgradeTestLogic2)
	AddAuthorityMember(cross(cur), cur.Address())
	UpdateImpl(cross(cur), upgradeTestImplPath2)
	uassert.Equal(t, "vtest2", ImplVersion())

	tl := impl.(*upgradeTestLogic)
	uassert.Equal(t, upgradeTestImplPath, tl.prevPath)
	uassert.True(t, tl.store.HasDenom(d.IBCDenom()))

	// The callbacks' forwarding through the core-caller gate is covered by
	// every packet filetest.

	UpdateImpl(cross(cur), upgradeTestImplPath)
	uassert.Equal(t, upgradeTestImplPath, ImplPath())
	uassert.True(t, hasDenom(d.IBCDenom()))
}

func TestRenderDelegation(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	uassert.True(t, strings.HasPrefix(Render(""), "# IBC transfer"))
	registerAs(cur, upgradeTestImplPath, newUpgradeTestLogic)
	uassert.Equal(t, "rendered by vtest: ", Render(""))
	uassert.Equal(t, "rendered by vtest: vouchers?page=2", Render("vouchers?page=2"))
}

func TestReadOnlyViewsAndGates(cur realm, t *testing.T) {
	resetUpgradeState()
	defer resetUpgradeState()

	d := ics20.NewDenom("uatom", ics20.NewHop(PortID, "07-tendermint-1"))
	store.SetDenom(0, cur, d)
	view := store.Denoms()
	uassert.Equal(t, 1, view.Size())
	uassert.Equal(t, d.IBCDenom(), view.Get(d.IBCDenom()).(ics20.Denom).IBCDenom())
	uassert.PanicsContains(t, cur, "read-only tree", func() { view.Set("k", 1) })

	// The voucher view hands out tokens, never the voucher entry with its ledger.
	tok := store.GetOrCreateVoucher(0, cur, "uatom", d.IBCDenom())
	uassert.Equal(t, tok.GetSymbol(), store.Vouchers().Get(d.IBCDenom()).(*grc20.Token).GetSymbol())
	uassert.Equal(t, 1, store.Vouchers().Size())

	// A stale realm value is refused by the gated services.
	stale := captureRealm(cross(cur))
	uassert.PanicsContains(t, cur, "access denied", func() { store.SetDenom(0, stale, d) })
	uassert.PanicsContains(t, cur, "access denied", func() { store.MintVoucher(0, stale, d.IBCDenom(), cur.Address(), 1) })
	uassert.PanicsContains(t, cur, "access denied", func() { EmitTransfer(0, stale, "", "", "", "", "") })
}

func captureRealm(cur realm) realm { return cur }
