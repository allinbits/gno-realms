// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/runtime/unsafe"
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/gov/dao"
	daoinit "gno.land/r/gov/dao/init/v0"
)

const successorPath = "gno.land/r/third/party/successor"

// member is a GovDAO T1 member. It is not a member of the core authority: the
// replacement and the unregistration below can only come through the DAO.
var member address = unsafe.OriginCaller()

// The GovDAO path of ReplaceApp and UnregisterApp against the real r/gov/dao.
func main(cur realm) {
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	successor := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm(successorPath))
	core.RegisterApp(cross(cur), "app1", successor)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	daoinit.InitWithUsers(cross(cur), member)
	testing.SetOriginCaller(member)

	testing.SetRealm(testing.NewUserRealm(member))
	req := core.NewReplaceAppProposalRequest(cross(cur), "app1", successorPath)
	pid := dao.MustCreateProposal(cross(cur), req)
	println("proposal:", pid, "-", req.Title())
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))
	println("executed:", dao.ExecuteProposal(cross(cur), pid))
	println("active:", core.AppPkgPath("app1"))

	req = core.NewUnregisterAppProposalRequest(cross(cur), "app1")
	pid = dao.MustCreateProposal(cross(cur), req)
	println("proposal:", pid, "-", req.Title())
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))
	println("executed:", dao.ExecuteProposal(cross(cur), pid))
	println("active:", core.AppPkgPath("app1"))
}

// Output:
// proposal: 0000000 - gno.land/r/aib/ibc/core: replace app on port app1 with gno.land/r/third/party/successor
// executed: true
// active: gno.land/r/third/party/successor
// proposal: 0000001 - gno.land/r/aib/ibc/core: unregister app on port app1
// executed: true
// active:

// Events:
// [
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
//     "type": "app_registration_pending",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       },
//       {
//         "key": "pkg_path",
//         "value": "gno.land/r/third/party/successor"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "ProposalCreated",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "0"
//       }
//     ],
//     "pkg_path": "gno.land/r/gov/dao"
//   },
//   {
//     "type": "app_replaced",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       },
//       {
//         "key": "old_pkg_path",
//         "value": "gno.land/r/aib/main"
//       },
//       {
//         "key": "new_pkg_path",
//         "value": "gno.land/r/third/party/successor"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "ProposalCreated",
//     "attrs": [
//       {
//         "key": "id",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/r/gov/dao"
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
//         "value": "gno.land/r/third/party/successor"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
