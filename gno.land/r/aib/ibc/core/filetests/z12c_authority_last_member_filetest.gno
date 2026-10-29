// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// The governance realm cannot be removed from the authority: it changes the
// membership as a member, so removing it would freeze the membership and its
// tightening powers for good.
func main(cur realm) {
	ibcgov := chain.PackageAddress(core.IBCGovPath)
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.RemoveAuthorityMember(cross(cur), chain.PackageAddress(authority.GovDAOPath))
	println("members left: govdao", core.IsAuthorityMember(chain.PackageAddress(authority.GovDAOPath)), "ibcgov", core.IsAuthorityMember(ibcgov))
	core.RemoveAuthorityMember(cross(cur), ibcgov)
}

// Output:
// members left: govdao false ibcgov true

// Error:
// remove_authority_member: the governance realm stays a member
