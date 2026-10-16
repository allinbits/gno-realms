// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Authority (ADR pr6375 R14): GovDAO and ibcgov are the members from init,
// with no deployer. GovDAO blocks an address at once; unblocking it, like
// every loosening operation, is ibcgov's decision.
func main(cur realm) {
	govdao := chain.PackageAddress(authority.GovDAOPath)
	println("govdao member:", transfer.IsAuthorityMember(govdao))
	println("ibcgov member:", transfer.IsAuthorityMember(chain.PackageAddress(transfer.IBCGovPath)))
	println("main member:  ", transfer.IsAuthorityMember(cur.Address()))

	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	transfer.BlockAddress(cross(cur), "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx")
	println("blocked:", transfer.IsBlocked("g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"))
	println(transfer.Render("admin"))
}

// Output:
// govdao member: true
// ibcgov member: true
// main member:   false
// blocked: true
// ## Authority
//
// - **Authority members**:
//   - g12l3du5z70zzq9rkc82asre09srefve7p5mfay4
//   - g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r
// - **Paused**: false (set by the IBC core)
// - **Implementation**: [`gno.land/r/aib/ibc/apps/transfer/impl/v0`](/r/aib/ibc/apps/transfer/impl/v0) (version v0)
// - **Registered implementations**:
//   - gno.land/r/aib/ibc/apps/transfer/impl/v0
// - **Blocked addresses**:
//   - g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx
