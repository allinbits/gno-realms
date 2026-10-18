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

// ControlsLogic is implemented by an implementation that keeps the Ethereum
// route controls of ADR pr6375 §7 (impl/v1): the permissionless payouts of
// the claim queue and of the queued refunds, the recapitalization of a route's escrow, and the
// governance operations ibcgov decides. The proxy's entry points Claim,
// ClaimRefunds, ProveOutcome, ContinueReopen, PrepareReplacement, Recapitalize and GovApply forward to it
// non-crossing, as the other entry points do; an implementation without it
// refuses them.
type ControlsLogic interface {
	// Claim pays up to n claims of denom on the route of clientID and
	// returns how many it paid something on.
	Claim(_ int, rlm realm, clientID, denom string, n int) int
	// ClaimRefunds pays up to n queued refunds of denom on the route of
	// clientID and returns how many it paid something on.
	ClaimRefunds(_ int, rlm realm, clientID, denom string, n int) int
	// ProveOutcome stores the destination's outcome of a retired client's
	// send, proven through the route's replacement client.
	ProveOutcome(_ int, rlm realm, packet types.Packet, proofHeight types.Height, receiptProof, ackProof any)
	// ContinueReopen runs the next batch of a route's reopening and
	// reports whether the route is open.
	ContinueReopen(_ int, rlm realm, route string) bool
	// PrepareReplacement walks the next batch of a replaced route's retired
	// records, reserving the refunds they may owe, and reports whether the
	// preparation is complete.
	PrepareReplacement(_ int, rlm realm, route string, n int) bool
	// Recapitalize pays an authorized recapitalization into the escrow of
	// route: sent is the send envelope of a direct user call (a native
	// denom), empty otherwise (a GRC20, taken from the caller's allowance).
	Recapitalize(_ int, rlm realm, sent []chain.Coin, route string, id int64)
	// GovApply applies a governance operation; it returns "" when applied
	// and the reason otherwise, which spends the decision. Only ibcgov's
	// calls reach it.
	GovApply(_ int, rlm realm, op string, params []byte) string
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
	// implAddrs indexes every registered implementation by its realm
	// address, superseded ones included (a registry only grows): bridge
	// membership is one keyed lookup (IsImplAddress), whatever the number
	// registered.
	implAddrs = bptree.NewBPTree32() // realm address -> path
	// implManifests holds what each registered implementation declared
	// about itself, store-free: the preflight reads it and never builds a
	// candidate (ADR 0004, R14).
	implManifests = bptree.NewBPTree32() // path -> manifest
)

// manifest is what an implementation declares about itself when it
// registers, as plain values. KeepsControls answers from it alone;
// CheckUpdateImpl checks it, then builds the candidate against the empty
// sandboxStore (never the live store) and checks the built version and
// controls answer against it: candidate code runs in the preflight, but
// nothing is handed the live store before a governed installation. The
// installation checks the built implementation against it again.
type manifest struct {
	// Version is the Version() the implementation reports.
	Version string
	// Over lists the versions of an active implementation it installs over
	// ("" at bootstrap); it always re-installs over its own version. nil
	// installs over any.
	Over []string
	// KeepsControls declares that it implements ControlsLogic.
	KeepsControls bool
}

// accepts reports whether m installs over an active implementation of
// version prev.
func (m manifest) accepts(prev string) bool {
	if m.Over == nil || prev == m.Version {
		return true
	}
	for _, v := range m.Over {
		if v == prev {
			return true
		}
	}
	return false
}

// newManifest builds a manifest in this realm's storage: the caller's slice
// stays the caller's.
func newManifest(version string, over []string, keepsControls bool) manifest {
	m := manifest{Version: version, KeepsControls: keepsControls}
	if over != nil {
		m.Over = append([]string{}, over...)
	}
	return m
}

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
// requires UpdateImpl. version, over and keepsControls are its manifest: the
// version it reports, the versions of an active implementation it installs
// over ("" at bootstrap; its own version always; nil for any) and whether it
// keeps the route controls, which the preflight reads instead of building
// it.
func RegisterImpl(cur realm, ctor func(Store) Logic, version string, over []string, keepsControls bool) {
	caller := cur.Previous().PkgPath()
	if !strings.HasPrefix(caller, implPathPrefix) {
		panic(ufmt.Sprintf("RegisterImpl: caller %s is not under %s", caller, implPathPrefix))
	}
	if ctor == nil {
		panic("RegisterImpl: nil constructor")
	}
	if version == "" {
		panic("RegisterImpl: the manifest names no version")
	}
	// A registered implementation is a realm of the bridge: one at an
	// address a route pays its fees to would turn that collector into one.
	// The collector is changed first, by a governed (delayed) decision.
	if isFeeCollector(chain.PackageAddress(caller)) {
		panic(ufmt.Sprintf("RegisterImpl: %s is a route's fee collector: change the collector first", caller))
	}
	implCtors.Set(caller, ctor)
	implManifests.Set(caller, newManifest(version, over, keepsControls))
	implAddrs.Set(string(chain.PackageAddress(caller)), caller)
	if impl == nil {
		install(0, cur, caller)
	}
}

// UpdateImpl activates a registered implementation, identified by its realm
// path. Governance only (ADR pr6375 R14): an upgrade is a 7-day decision in
// ibcgov. The implementation is built against the proxy-owned store and its
// OnInstall hook runs before the switch, so a panic there leaves the previous
// implementation active. Rollback is UpdateImpl with the previous path.
func UpdateImpl(cur realm, path string) {
	assertGovernance(0, cur, "update_impl")
	install(0, cur, path)
}

func install(_ int, rlm realm, path string) {
	v := implCtors.Get(path)
	if v == nil {
		panic(ufmt.Sprintf("no implementation registered at %s", path))
	}
	// Only here, in an authorized installation (bootstrap or a governed
	// UpdateImpl), is candidate code given the store.
	ctor := v.(func(Store) Logic)
	l := ctor(store)
	if l == nil {
		panic(ufmt.Sprintf("implementation %s returned a nil Logic", path))
	}
	_, keeps := l.(ControlsLogic)
	if m := implManifests.Get(path).(manifest); l.Version() != m.Version || keeps != m.KeepsControls {
		panic(ufmt.Sprintf("implementation %s is not what its manifest declared (version %s, keeps controls %t)", path, m.Version, m.KeepsControls))
	}
	if refusal := controlsContinuity(keeps); refusal != "" {
		panic(refusal)
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

// InstallChecker is implemented by an implementation whose OnInstall
// refuses some predecessors: CheckInstall is why it would, or nil, as a
// pure function of the plain values the proxy passes (the active
// implementation's path and version), so the preflight evaluates exactly
// what OnInstall will.
type InstallChecker interface {
	CheckInstall(prevPath, prevVersion string) error
}

// CheckUpdateImpl is why UpdateImpl(path) would fail now, or "", with no
// change: path is not registered, its manifest does not install over the
// active version, it drops the route controls, or the implementation its
// constructor builds disagrees with its manifest or refuses the active
// implementation (InstallChecker). A governed switch that would fail is
// refused (and its decision spent) instead of aborting and staying pending.
// The candidate is built against an empty sandbox store (sandboxStore),
// never the live one: the live store reaches candidate code only in an
// authorized installation.
func CheckUpdateImpl(path string) string {
	v := implManifests.Get(path)
	if v == nil {
		return "no implementation registered at " + path
	}
	m := v.(manifest)
	if refusal := controlsContinuity(m.KeepsControls); refusal != "" {
		return refusal
	}
	if !m.accepts(implVersion) {
		return ufmt.Sprintf("transfer impl %s cannot install over version %s", m.Version, implVersion)
	}
	l := implCtors.Get(path).(func(Store) Logic)(sandboxStore{})
	if l == nil {
		return "implementation " + path + " returned a nil Logic"
	}
	_, keeps := l.(ControlsLogic)
	if l.Version() != m.Version || keeps != m.KeepsControls {
		return ufmt.Sprintf("implementation %s is not what its manifest declared (version %s, keeps controls %t): it builds version %s, keeps controls %t",
			path, m.Version, m.KeepsControls, l.Version(), keeps)
	}
	if ic, ok := l.(InstallChecker); ok {
		if err := ic.CheckInstall(implPath, implVersion); err != nil {
			return err.Error()
		}
	}
	return ""
}

// controlsContinuity refuses an implementation without the route controls
// once any route has them (ADR pr6375 §5.4): it would move value on Ethereum
// routes without keeping their send records, meters and supply accounting,
// so a reinstalled controls implementation would trust stale state (refund
// a packet a second time). The controls are never rolled back.
func controlsContinuity(keepsControls bool) string {
	if keepsControls {
		return ""
	}
	if rd, ok := store.ExtView("controls").(interface{ Routes() []string }); ok && len(rd.Routes()) > 0 {
		return "transfer: an implementation without the route controls cannot replace them once a route has them"
	}
	return ""
}

// KeepsControls reports whether the implementation registered at path
// declared it keeps the route controls (ControlsLogic), from its manifest:
// nothing is built. The installation checks the declaration.
func KeepsControls(path string) bool {
	v := implManifests.Get(path)
	return v != nil && v.(manifest).KeepsControls
}

// ImplPath returns the realm path of the active implementation, "" if none.
func ImplPath() string {
	return implPath
}

// ImplVersion returns the Version() of the active implementation, "" if none.
func ImplVersion() string {
	return implVersion
}

// IsRegisteredImpl reports whether an implementation is registered at path:
// a keyed lookup.
func IsRegisteredImpl(path string) bool { return implCtors.Get(path) != nil }

// IsImplAddress reports whether a is the realm address of a registered
// implementation, superseded ones included: a keyed lookup, whatever the
// number registered.
func IsImplAddress(a address) bool { return implAddrs.Get(string(a)) != nil }

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

func mustControls() ControlsLogic {
	c, ok := mustImpl().(ControlsLogic)
	if !ok {
		panic("transfer: the active implementation " + implVersion + " keeps no route controls")
	}
	return c
}

func mustImpl() Logic {
	if impl == nil {
		panic("transfer: no implementation installed")
	}
	return impl
}
