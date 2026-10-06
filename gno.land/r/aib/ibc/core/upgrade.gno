package core

import (
	"chain"
	"strings"

	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

// corePkgPath is the permanent package path of this proxy realm. It is part of
// the on-chain contract with counterparties and relayers: chain params are
// namespaced "vm:<current realm>:<key>" and events carry the emitting package,
// so the packet state must always be written, and the events emitted, by this
// realm (see ADR 0001). That is why the lifecycle logic lives behind the Logic
// interface in a separate implementation realm, invoked non-crossing, while
// this realm stays a thin, frozen proxy at this path.
const corePkgPath = "gno.land/r/aib/ibc/core"

// implPathPrefix is the namespace implementations must live in.
const implPathPrefix = corePkgPath + "/impl/"

const (
	EventTypeImplUpdated = "impl_updated"
	AttributeKeyOldPath  = "old_path"
	AttributeKeyNewPath  = "new_path"
	AttributeKeyVersion  = "version"
)

// Logic is the swappable client and packet lifecycle implementation. Methods
// take the non-crossing (_ int, rlm realm, ...) form on purpose: the
// dispatchers forward this realm's own cur without a realm transition, so the
// current realm stays corePkgPath throughout. The implementation therefore
// runs "as" this proxy: rlm.Previous() is the proxy's caller, app callbacks
// are issued with cross(rlm), and the gated store accessors and Emit* wrappers
// accept rlm.
type Logic interface {
	// Version identifies the implementation, shown in Render and in the
	// impl_updated event.
	Version() string
	// OnInstall runs inside UpdateImpl, after the implementation is built
	// against the store and before any entry point reaches it. It is the
	// migration hook: it must be idempotent (it runs again on re-install and
	// on rollback) and cheap. A panic aborts the switch. prevPath and
	// prevVersion are empty at bootstrap.
	OnInstall(_ int, rlm realm, prevPath, prevVersion string)
	// Render serves every path: the proxy's Render forwards to it. The JSON
	// routes the relayer reads through vm/qrender (clients, clients/{id},
	// its consensus states, packet commitments and receipts) are a
	// compatibility contract: their shape is pinned by the z0c filetest and
	// changing it means a relayer release.
	Render(path string) string

	CreateClient(_ int, rlm realm, relayer address, clientState lightclient.ClientState, consensusState lightclient.ConsensusState) string
	RegisterCounterparty(_ int, rlm realm, clientID string, counterpartyMerklePrefix [][]byte, counterpartyClientID string)
	UpdateClient(_ int, rlm realm, clientID string, clientMessage lightclient.ClientMessage)
	UpgradeClient(_ int, rlm realm, clientID string, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState any)
	RecoverClient(_ int, rlm realm, subjectClientID, substituteClientID string)
	SendPacket(_ int, rlm realm, msg types.MsgSendPacket) (sequence uint64)
	RecvPacket(_ int, rlm realm, msg types.MsgRecvPacket) types.ResponseResultType
	WriteAcknowledgement(_ int, rlm realm, clientID string, sequence uint64, ack types.Acknowledgement)
	Acknowledgement(_ int, rlm realm, msg types.MsgAcknowledgement) types.ResponseResultType
	Timeout(_ int, rlm realm, msg types.MsgTimeout) types.ResponseResultType
}

var (
	// impl is the active implementation; nil until the first registration.
	impl        Logic
	implPath    string
	implVersion string
	// implCtors holds the registered constructors keyed by implementation
	// path. A constructor receives the proxy-owned store so a swapped
	// implementation reads and writes the same persistent state: clients,
	// commitments, receipts and acknowledgements survive an upgrade.
	implCtors = bptree.NewBPTree32() // path -> func(Store) Logic
)

// assertProxyRealm guards the exported store mutators and Emit* wrappers. The
// active implementation is always invoked non-crossing by the dispatchers, so
// the realm value it forwards is this realm's own live cur: rlm.IsCurrent() is
// true and rlm.PkgPath() == corePkgPath. A foreign realm cannot satisfy both
// predicates, and a stale copy of this realm's cur fails the first.
func assertProxyRealm(_ int, rlm realm) {
	if !rlm.IsCurrent() || rlm.PkgPath() != corePkgPath {
		panic("core: access denied for non-proxy realm " + rlm.PkgPath())
	}
}

// RegisterImpl records an implementation constructor. It must be called from
// a realm under corePkgPath + "/impl/" (e.g. gno.land/r/aib/ibc/core/impl/v1),
// normally from that realm's init, so the set of installable implementations
// is confined to this realm's own namespace, which only the owner of the aib
// namespace can deploy under. Registration alone activates nothing, except
// for the very first one while no implementation is installed (bootstrap):
// genesis needs no extra transaction and tests only a blank import. Every
// later switch requires UpdateImpl.
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
		panic("core: no implementation installed")
	}
	return impl
}
