// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/apps/transfer"

// Block / unblock round trip by the admin; the admin page lists the blocklist.
func main(cur realm) {
	transfer.SetAdmin(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
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
// ## Admin
//
// - **Admin**: g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
// - **Paused**: false
// - **Blocked addresses**:
//   - g1someother00000000000000000000000000
//
// blocked: false
// ## Admin
//
// - **Admin**: g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
// - **Paused**: false
// - **Blocked addresses**: none

// Events:
// [
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
