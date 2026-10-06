// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/core"
)

// The last member of the authority cannot be removed.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.RemoveAuthorityMember(cross(cur), chain.PackageAddress(authority.GovDAOPath))
	println("members left: govdao", core.IsAuthorityMember(chain.PackageAddress(authority.GovDAOPath)), "main", core.IsAuthorityMember(cur.Address()))
	core.RemoveAuthorityMember(cross(cur), cur.Address())
}

// Output:
// members left: govdao false main true

// Error:
// authority: cannot remove the last member
