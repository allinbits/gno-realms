// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/apps/transfer"
)

// Authority: GovDAO is a member from the start, the bootstrap admits this realm,
// and the GovDAO path (previous realm = the DAO proxy) can block an address.
func main(cur realm) {
	govdao := chain.PackageAddress(authority.GovDAOPath)
	println("govdao member:", transfer.IsAuthorityMember(govdao))
	transfer.AddAuthorityMember(cross(cur), cur.Address())
	println("main member:  ", transfer.IsAuthorityMember(cur.Address()))

	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	transfer.BlockAddress(cross(cur), "g1someother00000000000000000000000000")
	println("blocked:", transfer.IsBlocked("g1someother00000000000000000000000000"))
	println(transfer.Render("admin"))
}

// Output:
// govdao member: true
// main member:   true
// blocked: true
// ## Authority
//
// - **Authority members**:
//   - g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9
//   - g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r
// - **Paused**: false (set by the IBC core)
// - **Blocked addresses**:
//   - g1someother00000000000000000000000000

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
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "block",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1someother00000000000000000000000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
