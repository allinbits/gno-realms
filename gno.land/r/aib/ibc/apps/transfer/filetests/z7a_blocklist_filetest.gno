// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/apps/transfer"

// Block / unblock round trip by the admin; the admin page lists the blocklist.
func main(cur realm) {
	transfer.AddAuthorityMember(cross(cur), cur.Address())
	println("blocked:", transfer.IsBlocked("g1someother00000000000000000000000000"))
	transfer.BlockAddress(cross(cur), "g1someother00000000000000000000000000")
	println("blocked:", transfer.IsBlocked("g1someother00000000000000000000000000"))
	println(transfer.Render("admin"))
	transfer.UnblockAddress(cross(cur), "g1someother00000000000000000000000000")
	println("blocked:", transfer.IsBlocked("g1someother00000000000000000000000000"))
	println(transfer.Render("admin"))
}

// Output:
// blocked: false
// blocked: true
// ## Authority
//
// - **Authority members**:
//   - g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9
//   - g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r
// - **Paused**: false (set by the IBC core)
// - **Blocked addresses**:
//   - g1someother00000000000000000000000000
//
// blocked: false
// ## Authority
//
// - **Authority members**:
//   - g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9
//   - g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r
// - **Paused**: false (set by the IBC core)
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
//     "type": "block",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1someother00000000000000000000000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "unblock",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1someother00000000000000000000000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
