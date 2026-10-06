// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/core"
)

// Authority: GovDAO is a member from the start, the test-framework bootstrap
// (deployer unknown at init) makes the first AddAuthorityMember ungated, then
// members manage relayers and membership; the admin page lists them.
func main(cur realm) {
	govdao := chain.PackageAddress(authority.GovDAOPath)
	println("govdao member:", core.IsAuthorityMember(govdao))
	println("main member:  ", core.IsAuthorityMember(cur.Address()))

	// Calls from this realm present its own address as principal.
	core.AddAuthorityMember(cross(cur), cur.Address())
	println("main member:  ", core.IsAuthorityMember(cur.Address()))
	core.AddRelayer(cross(cur), "g1relayer000000000000000000000000000000")
	println(core.Render("admin"))

	// GovDAO acts through callbacks declared in this realm, whose previous
	// realm is the DAO proxy: simulate that caller.
	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	core.RemoveRelayer(cross(cur), "g1relayer000000000000000000000000000000")
	core.AddAuthorityMember(cross(cur), "g1someother00000000000000000000000000")
	println(core.Render("admin"))
}

// Output:
// govdao member: true
// main member:   false
// main member:   true
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g1gjs8…qxd9](/u/g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Relayers**:
//   - [g1rela…0000](/u/g1relayer000000000000000000000000000000)
//
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g1gjs8…qxd9](/u/g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
//   - [g1some…0000](/u/g1someother00000000000000000000000000)
// - **Paused**: false
// - **Relayers**: any (whitelist empty)

// Events:
// [
//   {
//     "type": "authority_member_added",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "authority_member_added",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1someother00000000000000000000000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
