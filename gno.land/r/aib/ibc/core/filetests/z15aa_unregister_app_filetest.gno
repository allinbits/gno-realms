// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// UnregisterApp frees a port, which can then be registered again.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	core.PauseApp(cross(cur), "app1")

	core.UnregisterApp(cross(cur), "app1")
	println("active:", core.AppPkgPath("app1"), "paused:", core.IsAppPaused("app1"))
	println("apps:", core.Render("apps"))

	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	println("active:", core.AppPkgPath("app1"), "paused:", core.IsAppPaused("app1"))
}

// Output:
// active:  paused: false
// apps: []
// active: gno.land/r/aib/main paused: false

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
//     "type": "app_unregistered",
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
//   }
// ]
