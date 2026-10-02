package transfer

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/nt/ufmt/v0"
)

const (
	EventTypePause   = "pause"
	EventTypeUnpause = "unpause"
)

var (
	admin  address
	paused bool
)

func init() {
	// Set admin to the deployer's EOA, same bootstrap as r/aib/ibc/core: in
	// the gno test framework OriginCaller is "" here, so SetAdmin acts as the
	// bootstrap.
	admin = unsafe.OriginCaller()
}

// SetAdmin sets or transfers the admin role. If no admin is set, the first
// caller becomes admin; once set, only the current admin can change it.
func SetAdmin(cur realm, newAdmin address) {
	if admin != "" {
		ensureAdminCaller()
	}
	admin = newAdmin
}

// Pause suspends the app: Transfer panics and OnRecvPacket answers every
// incoming packet with an error acknowledgement (so the counterparty refunds
// its sender) until Unpause. Refunds through OnAcknowledgementPacket and
// OnTimeoutPacket keep working, so no user funds are held back by a pause.
// Can only be called by the admin.
func Pause(cur realm) {
	ensureAdminCaller()
	paused = true
	chain.Emit(EventTypePause)
}

// Unpause resumes the app. Can only be called by the admin.
func Unpause(cur realm) {
	ensureAdminCaller()
	paused = false
	chain.Emit(EventTypeUnpause)
}

// Paused reports whether the app is suspended.
func Paused() bool {
	return paused
}

// ensureAdminCaller panics if the EOA that signed the tx is not the admin.
// Same EOA-binding rationale and trade-off as r/aib/ibc/core/admin.gno.
func ensureAdminCaller() {
	caller := unsafe.OriginCaller()
	if caller != admin {
		panic(ufmt.Sprintf("unauthorized: caller %s is not the admin", caller))
	}
}

// ensureNotPaused panics if the app is suspended.
func ensureNotPaused() {
	if paused {
		panic("transfer is paused")
	}
}
