// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Unblocking loosens, so not even GovDAO does it directly: it is an ibcgov
// decision (ADR pr6375 R14).
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	transfer.BlockAddress(cross(cur), "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx")
	transfer.UnblockAddress(cross(cur), "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx")
}

// Error:
// unblock_address: only gno.land/r/aib/ibc/ibcgov decides this, not gno.land/r/gov/dao
