// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// PauseApp / UnpauseApp round trip by the authority; the apps page shows it.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	println("paused:", core.IsAppPaused("app1"))
	core.PauseApp(cross(cur), "app1")
	println("paused:", core.IsAppPaused("app1"))
	println(core.Render("apps"))
	core.UnpauseApp(cross(cur), "app1")
	println("paused:", core.IsAppPaused("app1"))
	println("unknown port paused:", core.IsAppPaused("nope"))
}

// Output:
// paused: false
// paused: true
// [{"port_id":"app1","pkg_path":"gno.land/r/aib/main","address":"g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9","paused":true}]
// paused: false
// unknown port paused: false

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
//     "type": "app_registered",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       },
//       {
//         "key": "pkg_path",
//         "value": "gno.land/r/aib/main"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "app_paused",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "app_unpaused",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
