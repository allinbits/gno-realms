package core

import (
	"chain"
	"strings"

	"gno.land/p/aib/ibc/app"
	"gno.land/p/aib/ibc/host"
	"gno.land/p/nt/ufmt/v0"
)

// trustedAppPrefix is this project's realm namespace. Only the owner of the
// `aib` namespace can deploy under it (r/sys/names), so a registration coming
// from there activates at once; anything else waits for the authority.
const trustedAppPrefix = "gno.land/r/aib/"

const (
	EventTypeAppRegistered = "app_registered"
	EventTypeAppPending    = "app_registration_pending"
	EventTypeAppApproved   = "app_approved"
	EventTypeAppRejected   = "app_rejected"
)

// RegisterApp registers an IBCApp for portID. The app is identified by the
// calling realm, hence it must be a realm. A registration from this project's
// namespace (trustedAppPrefix) is active immediately. Any other realm's
// registration is only recorded as pending, routes nothing, and is activated
// by the authority with ApproveApp (directly, or through a GovDAO proposal
// built with NewApproveAppProposalRequest). Pending registrations claim no
// port: several candidates may wait for the same one, and none can block a
// trusted app. A registration for a port that is already active is refused.
func RegisterApp(cur realm, portID string, a app.IBCApp) {
	caller := cur.Previous()
	if caller.IsUser() {
		panic("RegisterApp can only be called from an other realm")
	}
	if err := host.PortIdentifierValidator(portID); err != nil {
		panic(ufmt.Errorf("invalid portID: %v", err))
	}
	if _, ok := store.routes[portID]; ok {
		panic(ufmt.Errorf("portID %s has already been registered", portID))
	}
	entry := ibcApp{
		IBCApp:  a,
		pkgPath: caller.PkgPath(),
		address: caller.Address(),
	}
	if strings.HasPrefix(entry.pkgPath, trustedAppPrefix) {
		store.routes[portID] = entry
		chain.Emit(EventTypeAppRegistered, "port", portID, "pkg_path", entry.pkgPath)
		return
	}
	store.pendingApps.Set(pendingKey(portID, entry.pkgPath), entry)
	chain.Emit(EventTypeAppPending, "port", portID, "pkg_path", entry.pkgPath)
}

// ApproveApp activates the pending registration of pkgPath for portID.
// Authority members only; see proposals.gno for the GovDAO path.
func ApproveApp(cur realm, portID, pkgPath string) {
	approveApp(0, cur, portID, pkgPath)
}

func approveApp(_ int, rlm realm, portID, pkgPath string) {
	auth.Assert(0, rlm, "approve_app")
	key := pendingKey(portID, pkgPath)
	v := store.pendingApps.Get(key)
	if v == nil {
		panic(ufmt.Sprintf("no pending registration of %s for port %s", pkgPath, portID))
	}
	if _, ok := store.routes[portID]; ok {
		panic(ufmt.Errorf("portID %s has already been registered", portID))
	}
	store.routes[portID] = v.(ibcApp)
	store.pendingApps.Remove(key)
	chain.Emit(EventTypeAppApproved, "port", portID, "pkg_path", pkgPath)
}

// RejectApp drops the pending registration of pkgPath for portID. Authority
// members only. The storage deposit the entry held is refunded to the sender
// of this transaction, as for any deletion.
func RejectApp(cur realm, portID, pkgPath string) {
	rejectApp(0, cur, portID, pkgPath)
}

func rejectApp(_ int, rlm realm, portID, pkgPath string) {
	auth.Assert(0, rlm, "reject_app")
	key := pendingKey(portID, pkgPath)
	if !store.pendingApps.Has(key) {
		panic(ufmt.Sprintf("no pending registration of %s for port %s", pkgPath, portID))
	}
	store.pendingApps.Remove(key)
	chain.Emit(EventTypeAppRejected, "port", portID, "pkg_path", pkgPath)
}

// IsAppPending reports whether pkgPath has a pending registration for portID.
func IsAppPending(portID, pkgPath string) bool {
	return store.pendingApps.Has(pendingKey(portID, pkgPath))
}

// pendingKey joins a port and a package path. ':' is not a valid port
// identifier character (host.IsValidID), so the key is unambiguous.
func pendingKey(portID, pkgPath string) string {
	return portID + ":" + pkgPath
}
