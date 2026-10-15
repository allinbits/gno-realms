package core

import (
	"chain"
	"strings"

	"gno.land/p/aib/ibc/app/v0"
	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/nt/ufmt/v0"
)

// trustedAppPrefix is this project's realm namespace. Only the owner of the
// `aib` namespace can deploy under it (r/sys/names), so a registration coming
// from there activates at once; anything else waits for the authority.
const trustedAppPrefix = "gno.land/r/aib/"

const (
	EventTypeAppRegistered   = "app_registered"
	EventTypeAppPending      = "app_registration_pending"
	EventTypeAppApproved     = "app_approved"
	EventTypeAppRejected     = "app_rejected"
	EventTypeAppPaused       = "app_paused"
	EventTypeAppUnpaused     = "app_unpaused"
	EventTypeAppUnregistered = "app_unregistered"
	EventTypeAppReplaced     = "app_replaced"
)

// RegisterApp registers an IBCApp for portID. The app is identified by the
// calling realm, hence it must be a realm. A registration from this project's
// namespace (trustedAppPrefix) is active immediately. Any other realm's
// registration is only recorded as pending, routes nothing, and is activated
// by the authority with ApproveApp (directly, or through a GovDAO proposal
// built with NewApproveAppProposalRequest). Pending registrations claim no
// port: several candidates may wait for the same one, and none can block a
// trusted app. A registration for a port that is already active is recorded as
// pending whatever its namespace: it can only take the port through ReplaceApp.
// The active app registering its own port again is refused.
func RegisterApp(cur realm, portID string, a app.IBCApp) {
	caller := cur.Previous()
	if caller.IsUser() {
		panic("RegisterApp can only be called from an other realm")
	}
	if err := host.PortIdentifierValidator(portID); err != nil {
		panic(ufmt.Errorf("invalid portID: %v", err))
	}
	entry := App{
		IBCApp:  a,
		PkgPath: caller.PkgPath(),
		Address: caller.Address(),
	}
	active, taken := store.routes[portID]
	if taken && active.PkgPath == entry.PkgPath {
		panic(ufmt.Errorf("portID %s has already been registered", portID))
	}
	if !taken && strings.HasPrefix(entry.PkgPath, trustedAppPrefix) {
		store.routes[portID] = entry
		chain.Emit(EventTypeAppRegistered, "port", portID, "pkg_path", entry.PkgPath)
		return
	}
	store.pendingApps.Set(pendingKey(portID, entry.PkgPath), entry)
	chain.Emit(EventTypeAppPending, "port", portID, "pkg_path", entry.PkgPath)
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
	store.routes[portID] = v.(App)
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

// UnregisterApp frees portID: packets for that port are no longer routed, and
// any realm may register it again. Authority members only; see proposals.gno for
// the GovDAO path. Refused while the app owes an asynchronous acknowledgement,
// which only it may write.
//
// Packets the app sent and that are still in flight lose their app: their
// acknowledgement or timeout finds no route, so the refund the app owes its
// senders cannot run until a successor holds the port. Pause the app first
// and wait for in-flight packets to settle before unregistering it.
func UnregisterApp(cur realm, portID string) {
	unregisterApp(0, cur, portID)
}

func unregisterApp(_ int, rlm realm, portID string) {
	auth.Assert(0, rlm, "unregister_app")
	current := mustActiveApp(portID)
	assertNoPendingAsyncAck(current.PkgPath)
	delete(store.routes, portID)
	chain.Emit(EventTypeAppUnregistered, "port", portID, "pkg_path", current.PkgPath)
}

// ReplaceApp hands portID from its active app to the pending registration of
// pkgPath, in one step, so the port is never free between two transactions. The
// successor registers first with RegisterApp, which records it as pending
// because the port is taken. It inherits the pause state of the port, so a
// paused port stays paused until UnpauseApp. Authority members only; see
// proposals.gno for the GovDAO path. Refused while the current app owes an
// asynchronous acknowledgement, which only it may write.
//
// Acknowledgements and timeouts of packets the previous app sent are routed to
// the successor, which must be able to refund them (a successor sharing the
// previous app's state, or a port drained first by PauseApp).
func ReplaceApp(cur realm, portID, pkgPath string) {
	replaceApp(0, cur, portID, pkgPath)
}

func replaceApp(_ int, rlm realm, portID, pkgPath string) {
	auth.Assert(0, rlm, "replace_app")
	current := mustActiveApp(portID)
	key := pendingKey(portID, pkgPath)
	v := store.pendingApps.Get(key)
	if v == nil {
		panic(ufmt.Sprintf("no pending registration of %s for port %s", pkgPath, portID))
	}
	assertNoPendingAsyncAck(current.PkgPath)
	successor := v.(App)
	successor.Paused = current.Paused
	store.routes[portID] = successor
	store.pendingApps.Remove(key)
	chain.Emit(EventTypeAppReplaced, "port", portID, "old_pkg_path", current.PkgPath, "new_pkg_path", pkgPath)
}

func mustActiveApp(portID string) App {
	a, ok := store.routes[portID]
	if !ok {
		panic(ufmt.Sprintf("no registered app for port %s", portID))
	}
	return a
}

// assertNoPendingAsyncAck panics if pkgPath still owes an asynchronous
// acknowledgement: WriteAcknowledgement only accepts it from that realm, so
// swapping or dropping its route would strand it. The check is per realm, not
// per port, which is stricter for a realm holding several ports.
func assertNoPendingAsyncAck(pkgPath string) {
	store.clientByID.Iterate("", "", func(_ string, v any) bool {
		c := v.(*client)
		c.pendingAsyncAcksBySeq.Iterate("", "", func(_ string, p any) bool {
			ack := p.(*pendingAsyncAck)
			if ack.appPkgPath == pkgPath {
				panic(ufmt.Sprintf("%s owes an asynchronous acknowledgement on client %s for sequence %d", pkgPath, c.id, ack.packet.Sequence))
			}
			return false
		})
		return false
	})
}

// AppPkgPath returns the realm registered on portID, or "" if the port is
// free.
func AppPkgPath(portID string) string {
	a, ok := store.routes[portID]
	if !ok {
		return ""
	}
	return a.PkgPath
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

// PauseApp suspends the application registered on portID: SendPacket refuses
// payloads for that port, so a user's send fails and nothing moves, and
// RecvPacket answers incoming packets for it with the error acknowledgement
// without invoking the app, so the counterparty refunds its senders. The
// Acknowledgement and Timeout callbacks keep running, so refunds already owed
// by the app are never held back. Authority members only; see proposals.gno for
// the GovDAO path, and Pause for suspending the whole packet path instead.
func PauseApp(cur realm, portID string) {
	pauseApp(0, cur, portID)
}

func pauseApp(_ int, rlm realm, portID string) {
	auth.Assert(0, rlm, "pause_app")
	setAppPaused(portID, true)
	chain.Emit(EventTypeAppPaused, "port", portID)
}

// UnpauseApp resumes the application registered on portID. Authority members
// only.
func UnpauseApp(cur realm, portID string) {
	unpauseApp(0, cur, portID)
}

func unpauseApp(_ int, rlm realm, portID string) {
	auth.Assert(0, rlm, "unpause_app")
	setAppPaused(portID, false)
	chain.Emit(EventTypeAppUnpaused, "port", portID)
}

// IsAppPaused reports whether the application on portID is suspended. False
// for an unregistered port.
func IsAppPaused(portID string) bool {
	a, ok := store.routes[portID]
	return ok && a.Paused
}

func setAppPaused(portID string, paused bool) {
	a, ok := store.routes[portID]
	if !ok {
		panic(ufmt.Sprintf("no registered app for port %s", portID))
	}
	a.Paused = paused
	store.routes[portID] = a
}
