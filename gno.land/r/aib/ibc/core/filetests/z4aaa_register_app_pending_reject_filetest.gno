// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// The authority can drop a pending registration.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	app := appstesting.NewApp(cross(cur))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/app"))
	core.RegisterApp(cross(cur), "thirdparty", app)
	println("pending:", core.IsAppPending("thirdparty", "gno.land/r/third/party/app"))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.RejectApp(cross(cur), "thirdparty", "gno.land/r/third/party/app")
	println("pending:", core.IsAppPending("thirdparty", "gno.land/r/third/party/app"))
	println("apps/pending:", core.Render("apps/pending"))
}

// Output:
// pending: true
// pending: false
// apps/pending: {"total":0,"pending":[]}

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
//     "type": "app_registration_pending",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "thirdparty"
//       },
//       {
//         "key": "pkg_path",
//         "value": "gno.land/r/third/party/app"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "app_rejected",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "thirdparty"
//       },
//       {
//         "key": "pkg_path",
//         "value": "gno.land/r/third/party/app"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
