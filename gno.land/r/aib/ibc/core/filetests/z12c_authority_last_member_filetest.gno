// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// The last member of the authority cannot be removed.
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
// authority: cannot remove the last member
