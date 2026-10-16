// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// GovDAO's direct proposals cannot upgrade the core: an upgrade is an ibcgov
// decision, which waits for its delay (ADR pr6375 R14).
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	core.UpdateImpl(cross(cur), "gno.land/r/aib/ibc/core/impl/v0")
}

// Error:
// update_impl: only gno.land/r/aib/ibc/ibcgov decides this, not gno.land/r/gov/dao
