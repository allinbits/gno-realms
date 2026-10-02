// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/core"

// Pause / Unpause round trip by the admin; the admin page shows the state.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	println("paused:", core.Paused())
	core.Pause(cross(cur))
	println("paused:", core.Paused())
	println(core.Render("admin"))
	core.Unpause(cross(cur))
	println("paused:", core.Paused())
}

// Output:
// paused: false
// paused: true
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g1gjs8…qxd9](/u/g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: true
// - **Relayers**: any (whitelist empty)
//
// paused: false

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
//     "type": "pause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "unpause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
