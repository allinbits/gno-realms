package transfer

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/aib/ibc/types/v0"
)

// The entry points of the Ethereum route controls (ADR pr6375 §7.1, §7.9,
// §7.13), forwarded to the active implementation's ControlsLogic.

// Claim pays up to n (at most 20) claims of denom waiting on the route of
// clientID, within the route's meters, and returns how many it paid something
// on. Anyone may call it: credits from Ethereum are booked as claims and paid
// only this way. denom is the escrow denom of a gno-native token ("ugnot", a
// GRC20 alias) or the IBC denom of a voucher.
func Claim(cur realm, clientID, denom string, n int) int {
	return mustControls().Claim(0, cur, clientID, denom, n)
}

// ClaimRefunds pays up to n (at most 20) refunds of denom queued on the route
// of clientID under its refund meter, and returns how many it paid something
// on. Anyone may call it.
func ClaimRefunds(cur realm, clientID, denom string, n int) int {
	return mustControls().ClaimRefunds(0, cur, clientID, denom, n)
}

// Backfill records a send made over an Ethereum route before its controls
// (by impl/v0) whose commitment the core still holds: its acknowledgement or
// timeout is refused until it has a record, so the refund cannot bypass the
// refund meter or the refunds hold (ADR pr6375 §7.13). Anyone may call it
// with the packet; it is authenticated against the core's commitment.
func Backfill(cur realm, packet types.Packet) {
	mustControls().Backfill(0, cur, packet)
}

// Recapitalize pays recapitalization id of route, which an ibcgov decision
// authorized, into the route's escrow (ADR pr6375 §7.9). For a native denom
// it must be a direct user call sending exactly the amount; for a GRC20, the
// caller must have approved this realm for the amount. Anyone may pay it.
func Recapitalize(cur realm, route string, id int64) {
	var sent []chain.Coin
	if cur.Previous().IsUserCall() {
		sent = unsafe.OriginSend()
	}
	mustControls().Recapitalize(0, cur, sent, route, id)
}

// GovApply applies a governance operation of the route controls (see
// gno.land/p/aib/ibc/ics20/controls/v0, OpEnroll...). Only the ibcgov realm
// calls it, with a decision's parameters; it returns "" when applied and the
// reason otherwise.
func GovApply(cur realm, op string, params []byte) string {
	assertGovernance(0, cur, "gov_apply")
	// An implementation without the controls (a rollback to impl/v0) refuses
	// deterministically, so the decision is spent rather than left pending
	// until the controls come back.
	c, ok := mustImpl().(ControlsLogic)
	if !ok {
		return "the active implementation " + implVersion + " keeps no route controls"
	}
	return c.GovApply(0, cur, op, params)
}

// ExtView returns the read-only view of an implementation's extension state
// (see Store.ExtView), nil if none: for the route controls, under
// "controls", a gno.land/p/aib/ibc/ics20/controls/v0 Reader.
func ExtView(key string) any {
	return store.ExtView(key)
}
