// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/runtime/unsafe"
	"testing"

	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/gov/dao"
	daoinit "gno.land/r/gov/dao/init/v0"
)

// member is a GovDAO T1 member. It is not a member of the core authority:
// the pause below can only come through the DAO.
var member address = unsafe.OriginCaller()

// The GovDAO path of a tightening operation against the real r/gov/dao: a
// member proposes with the proxy's constructor, votes, anyone executes, and the
// callback runs with the DAO proxy as caller, which the authority accepts.
func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), member)
	testing.SetOriginCaller(member)
	testing.SetRealm(testing.NewUserRealm(member))

	req := core.NewPauseProposalRequest(cross(cur))
	pid := dao.MustCreateProposal(cross(cur), req)
	println("proposal:", pid, "-", req.Title())
	println("executor created in:", dao.MustGetProposal(pid).ExecutorCreationRealm())
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))

	println("before:", core.Paused())
	println("executed:", dao.ExecuteProposal(cross(cur), pid))
	println("after:", core.Paused())
}

// Output:
// proposal: 0000000 - gno.land/r/aib/ibc/core: pause
// executor created in: gno.land/r/aib/ibc/core
// before: false
// executed: true
// after: true

// Events:
// [
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
//     "type": "pause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
