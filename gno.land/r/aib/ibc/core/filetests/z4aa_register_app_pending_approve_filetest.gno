// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// A registration from outside this project's namespace is pending until the
// authority approves it; approved, it is routed like any other app.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	app := appstesting.NewApp(cross(cur))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/app"))
	core.RegisterApp(cross(cur), "thirdparty", app)
	println("pending:", core.IsAppPending("thirdparty", "gno.land/r/third/party/app"))
	println("apps:", core.Render("apps"))
	println("apps/pending:", core.Render("apps/pending"))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.ApproveApp(cross(cur), "thirdparty", "gno.land/r/third/party/app")
	println("pending:", core.IsAppPending("thirdparty", "gno.land/r/third/party/app"))
	println("apps:", core.Render("apps"))
	println("apps/pending:", core.Render("apps/pending"))
}

// Output:
// pending: true
// apps: []
// apps/pending: {"total":1,"pending":[{"pkg_path":"gno.land/r/third/party/app","address":"g1ewqw6mkxkg4ee75zpaslmw5f0q2wvwfsz3ykwp"}]}
// pending: false
// apps: [{"port_id":"thirdparty","pkg_path":"gno.land/r/third/party/app","address":"g1ewqw6mkxkg4ee75zpaslmw5f0q2wvwfsz3ykwp","paused":false}]
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
//     "type": "app_approved",
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
