// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/core"

// Pause / Unpause round trip by the admin; the admin page shows the state.
func main(cur realm) {
	core.SetAdmin(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
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
// ## Admin & Relayers
//
// - **Admin**: [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
// - **Paused**: true
// - **Relayers**: any (whitelist empty)
//
// paused: false

// Events:
// [
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
