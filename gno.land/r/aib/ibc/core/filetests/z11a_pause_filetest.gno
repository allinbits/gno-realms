// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Pause / Unpause round trip by the admin; the admin page shows the state.
func main(cur realm) {
	println("paused:", core.Paused())
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.Pause(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("paused:", core.Paused())
	println(core.Render("admin"))
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.Unpause(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("paused:", core.Paused())
}

// Output:
// paused: false
// paused: true
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g12l3d…fay4](/u/g12l3du5z70zzq9rkc82asre09srefve7p5mfay4)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: true
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
//   - [`gno.land/r/aib/ibc/core/impl/v1`](/r/aib/ibc/core/impl/v1)
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
