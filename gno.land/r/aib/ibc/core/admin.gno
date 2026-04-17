package core

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	admin    address
	relayers = avl.NewTree()
)

func init() {
	// Set admin to the deployer. In production this is always non-empty.
	// In the gno test framework the base store is pre-loaded with
	// OriginCaller="" so admin stays empty; SetAdmin then acts as bootstrap.
	admin = runtime.OriginCaller()
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

func ensureAdminCaller() {
	caller := runtime.OriginCaller()
	if caller != admin {
		panic(ufmt.Sprintf("unauthorized: caller %s is not the admin", caller))
	}
}

// ensureAuthorizedRelayer panics if the caller is not in the relayer whitelist.
func ensureAuthorizedRelayer() {
	caller := runtime.OriginCaller()
	if !relayers.Has(string(caller)) {
		panic(ufmt.Sprintf("unauthorized relayer %s", caller))
	}
}
