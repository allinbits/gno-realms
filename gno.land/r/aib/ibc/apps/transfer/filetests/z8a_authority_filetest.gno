// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/p/aib/authority"
	"gno.land/r/aib/ibc/apps/transfer"
)

// Authority: GovDAO is a member from the start, the bootstrap admits this realm,
// and the GovDAO path (previous realm = the DAO proxy) can pause the app.
func main(cur realm) {
	govdao := chain.PackageAddress(authority.GovDAOPath)
	println("govdao member:", transfer.IsAuthorityMember(govdao))
	transfer.AddAuthorityMember(cross(cur), cur.Address())
	println("main member:  ", transfer.IsAuthorityMember(cur.Address()))

	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	transfer.Pause(cross(cur))
	println("paused:", transfer.Paused())
	println(transfer.Render("admin"))
}

// Output:
// govdao member: true
// main member:   true
// paused: true
// ## Authority
//
// - **Authority members**:
//   - g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9
//   - g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r
// - **Paused**: true
// - **Blocked addresses**: none

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
//     "type": "pause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
