package core

import (
	"chain/runtime/unsafe"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	admin    address
	relayers = bptree.NewBPTree32()
)

func init() {
	// Set admin to the deployer's EOA. In production this is non-empty.
	// In the gno test framework the base store is pre-loaded with
	// OriginCaller="" so admin stays empty; SetAdmin then acts as bootstrap.
	admin = unsafe.OriginCaller()
}

// SetAdmin sets or transfers the admin role.
// If no admin is currently set (admin was not initialized in init, e.g. in
// tests), the first caller becomes admin. Once set, only the current admin
// can change it.
func SetAdmin(cur realm, newAdmin address) {
	if admin != "" {
		ensureAdminCaller()
	}
	admin = newAdmin
}

// AddRelayer adds an address to the authorized relayer whitelist.
// Can only be called by the admin.
func AddRelayer(cur realm, addr address) {
	ensureAdminCaller()
	relayers.Set(string(addr), true)
}

// RemoveRelayer removes an address from the authorized relayer whitelist.
// Can only be called by the admin.
func RemoveRelayer(cur realm, addr address) {
	ensureAdminCaller()
	relayers.Remove(string(addr))
}

// ensureAdminCaller panics if the EOA that signed the tx is not the admin.
// Uses unsafe.OriginCaller for tx-level EOA identity — admin authority is
// intentionally bound to the EOA that submitted the tx, which has no cur
// equivalent (cur.Previous() identifies the immediate frame, not the
// signer). Mirrors the v2 admin pattern in r/gnoland/blog/admin.gno.
//
// Trade-off: this allows the admin EOA to authorize admin ops through any
// intermediate realm (e.g. via maketx run, or a wrapper realm). That is
// the same tx.origin risk class as `runtime.OriginCaller` in v1; callers
// who set admin to an EOA must ensure that EOA does not call into
// untrusted code in the same tx.
func ensureAdminCaller() {
	caller := unsafe.OriginCaller()
	if caller != admin {
		panic(ufmt.Sprintf("unauthorized: caller %s is not the admin", caller))
	}
}

// ensureAuthorizedRelayer panics if the EOA that signed the tx is not in the
// relayer whitelist. If the whitelist is empty any EOA is allowed. Returns
// the relayer's EOA address. Same EOA-binding rationale as ensureAdminCaller.
func ensureAuthorizedRelayer() address {
	caller := unsafe.OriginCaller()
	if relayers.Size() == 0 {
		return caller
	}
	if !relayers.Has(string(caller)) {
		panic(ufmt.Sprintf("unauthorized relayer %s", caller))
	}
	return caller
}
