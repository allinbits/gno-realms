// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// The relayer list is a governance decision: not even GovDAO, a member of the
// authority, changes it directly (ADR pr6375 R14).
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	core.AddRelayer(cross(cur), "g1relayer000000000000000000000000000000")
}

// Error:
// add_relayer: only gno.land/r/aib/ibc/ibcgov decides this, not gno.land/r/gov/dao
