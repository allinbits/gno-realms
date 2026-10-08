package transfer

import (
	"chain"
	"strings"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

// PkgPath is the permanent package path of this proxy realm. It is part of
// the on-chain contract (see ADR 0002): this realm's address holds the
// escrow and the user approvals, the voucher tokens are registered in
// grc20reg under this path, and the IBC core routes port "transfer" to the
// App value this realm registered. That is why the ICS-20 logic lives behind
// the Logic interface in a separate implementation realm, invoked
// non-crossing, while this realm stays a thin, frozen proxy at this path.
const PkgPath = "gno.land/r/aib/ibc/apps/transfer"

// implPathPrefix is the namespace implementations must live in.
const implPathPrefix = PkgPath + "/impl/"

const (
	EventTypeImplUpdated = "impl_updated"
	AttributeKeyOldPath  = "old_path"
	AttributeKeyNewPath  = "new_path"
	AttributeKeyVersion  = "version"
)

// Logic is the swappable ICS-20 implementation. Methods take the non-crossing
// (_ int, rlm realm, ...) form on purpose: the proxy forwards its own cur
// without a realm transition, so the current realm stays PkgPath throughout.
// The implementation therefore runs "as" this proxy: rlm.Previous() is the
// proxy's caller (the EOA for Transfer, the IBC core for the callbacks), and
// the gated Store services and Emit* wrappers accept rlm.
type Logic interface {
	// Version identifies the implementation, shown in Render and in the
	// impl_updated event.
	Version() string
	// OnInstall runs inside UpdateImpl, after the implementation is built
	// against the store and before any entry point reaches it. It is the
	// migration hook, with the contract of the core's Logic.OnInstall: do
	// nothing when prevVersion is this version, migrate when it is the
	// version this one follows, panic otherwise. A panic aborts the whole
	// transaction, so the previous implementation stays active and nothing
	// the hook wrote persists. prevPath and prevVersion are empty at
	// bootstrap.
	OnInstall(_ int, rlm realm, prevPath, prevVersion string)
	// Render serves every path: the proxy's Render forwards to it. The
	// routes the e2e suite and tooling read (denoms, vouchers, voucher
	// balances, total escrow) are pinned by the z0e filetest.
	Render(path string) string

	// Transfer is the user-side logic behind the Transfer entry point: it
	// classifies the denom, records the send it authorizes for OnSendPacket
	// in the store, builds the packet and sends it through the IBC core.
	// sent is the send envelope of the transaction, read by the proxy (see
	// transfer.gno for why the implementation must not read it itself).
	Transfer(_ int, rlm realm, sent []chain.Coin, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (packet types.MsgSendPacket, sequence uint64)

	// The app.IBCApp callbacks, in the non-crossing form.
	OnSendPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error
	OnRecvPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult
	OnTimeoutPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error
	OnAcknowledgementPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, acknowledgement []byte, payload types.Payload) error
}

var (
	// impl is the active implementation; nil until the first registration.
	impl        Logic
	implPath    string
	implVersion string
	// implCtors holds the registered constructors keyed by implementation
	// path. A constructor receives the proxy-owned store so a swapped
	// implementation reads and writes the same persistent state.
	implCtors = bptree.NewBPTree32() // path -> func(Store) Logic
)

// assertProxyRealm guards the exported store mutators, the value moves and
// the Emit* wrappers. The active implementation is always invoked
// non-crossing by this realm, so the realm value it forwards is this realm's
// own live cur: rlm.IsCurrent() is true and rlm.PkgPath() == PkgPath. A
// foreign realm cannot satisfy both predicates, and a stale copy of this
// realm's cur fails the first.
func assertProxyRealm(_ int, rlm realm) {
	if !rlm.IsCurrent() || rlm.PkgPath() != PkgPath {
		panic("transfer: access denied for non-proxy realm " + rlm.PkgPath())
	}
}

// RegisterImpl records an implementation constructor. It must be called from
// a realm under PkgPath + "/impl/", normally from that realm's init, so the
// set of installable implementations is confined to this realm's own
// namespace. Registration alone activates nothing, except for the very first
// one while no implementation is installed (bootstrap). Every later switch
// requires UpdateImpl.
func RegisterImpl(cur realm, ctor func(Store) Logic) {
	caller := cur.Previous().PkgPath()
	if !strings.HasPrefix(caller, implPathPrefix) {
		panic(ufmt.Sprintf("RegisterImpl: caller %s is not under %s", caller, implPathPrefix))
	}
	if ctor == nil {
		panic("RegisterImpl: nil constructor")
	}
	implCtors.Set(caller, ctor)
	if impl == nil {
		install(0, cur, caller)
	}
}

// UpdateImpl activates a registered implementation, identified by its realm
// path. Authority members only; see proposals.gno for the GovDAO path. The
// implementation is built against the proxy-owned store and its OnInstall
// hook runs before the switch, so a panic there leaves the previous
// implementation active. Rollback is UpdateImpl with the previous path.
func UpdateImpl(cur realm, path string) {
	updateImpl(0, cur, path)
}

func updateImpl(_ int, rlm realm, path string) {
	auth.Assert(0, rlm, "update_impl")
	install(0, rlm, path)
}

func install(_ int, rlm realm, path string) {
	v := implCtors.Get(path)
	if v == nil {
		panic(ufmt.Sprintf("no implementation registered at %s", path))
	}
	ctor := v.(func(Store) Logic)
	l := ctor(store)
	if l == nil {
		panic(ufmt.Sprintf("implementation %s returned a nil Logic", path))
	}
	// A panic in the hook unwinds the transaction: nothing below runs and
	// nothing the hook wrote persists.
	l.OnInstall(0, rlm, implPath, implVersion)
	oldPath := implPath
	impl = l
	implPath = path
	implVersion = l.Version()
	chain.Emit(EventTypeImplUpdated,
		AttributeKeyOldPath, oldPath,
		AttributeKeyNewPath, path,
		AttributeKeyVersion, implVersion,
	)
}

// ImplPath returns the realm path of the active implementation, "" if none.
func ImplPath() string {
	return implPath
}

// ImplVersion returns the Version() of the active implementation, "" if none.
func ImplVersion() string {
	return implVersion
}

// RegisteredImplPaths returns the paths of the registered implementations,
// active or not, sorted lexically.
func RegisteredImplPaths() []string {
	paths := make([]string, 0, implCtors.Size())
	implCtors.IterateByOffset(0, implCtors.Size(), func(k string, _ any) bool {
		paths = append(paths, k)
		return false
	})
	return paths
}

func mustImpl() Logic {
	if impl == nil {
		panic("transfer: no implementation installed")
	}
	return impl
}
