// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/runtime/unsafe"
	"testing"

	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/gov/dao"
	daoinit "gno.land/r/gov/dao/init/v0"
)

const v99Path = "gno.land/r/aib/ibc/core/impl/v99"

type v99 struct{ core.Logic }

func (v99) Version() string { return "v99" }

func newV99(s core.Store) core.Logic { return v99{Logic: implv0.New(s)} }

// member is a GovDAO T1 member. It is not a member of the core authority:
// the switch below can only come through the DAO.
var member address = unsafe.OriginCaller()

// The GovDAO path of UpdateImpl against the real r/gov/dao: a member proposes
// with the proxy's constructor, votes, anyone executes, and the callback runs
// with the DAO proxy as caller, which the authority accepts.
func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), member)
	testing.SetOriginCaller(member)

	testing.SetRealm(testing.NewCodeRealm(v99Path))
	core.RegisterImpl(cross(cur), newV99)

	testing.SetRealm(testing.NewUserRealm(member))
	req := core.NewUpdateImplProposalRequest(cross(cur), v99Path)
	pid := dao.MustCreateProposal(cross(cur), req)
	println("proposal:", pid, "-", req.Title())
	println("executor created in:", dao.MustGetProposal(pid).ExecutorCreationRealm())
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))

	println("before:", core.ImplPath(), core.ImplVersion())
	println("executed:", dao.ExecuteProposal(cross(cur), pid))
	println("after:", core.ImplPath(), core.ImplVersion())
}

// Output:
// proposal: 0000000 - gno.land/r/aib/ibc/core: update implementation to gno.land/r/aib/ibc/core/impl/v99
// executor created in: gno.land/r/aib/ibc/core
// before: gno.land/r/aib/ibc/core/impl/v0 v0
// executed: true
// after: gno.land/r/aib/ibc/core/impl/v99 v99

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
//     "type": "impl_updated",
//     "attrs": [
//       {
//         "key": "old_path",
//         "value": "gno.land/r/aib/ibc/core/impl/v0"
//       },
//       {
//         "key": "new_path",
//         "value": "gno.land/r/aib/ibc/core/impl/v99"
//       },
//       {
//         "key": "version",
//         "value": "v99"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
