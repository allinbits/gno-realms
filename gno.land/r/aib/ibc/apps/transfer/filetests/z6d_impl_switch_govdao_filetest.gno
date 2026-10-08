// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/runtime/unsafe"
	"testing"

	"gno.land/r/aib/ibc/apps/transfer"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/gov/dao"
	daoinit "gno.land/r/gov/dao/init/v0"
)

const v99Path = "gno.land/r/aib/ibc/apps/transfer/impl/v99"

type v99 struct{ transfer.Logic }

func (v99) Version() string { return "v99" }

func newV99(s transfer.Store) transfer.Logic { return v99{Logic: implv0.New(s)} }

// member is a GovDAO T1 member, not a member of the transfer authority.
var member address = unsafe.OriginCaller()

// The GovDAO path of UpdateImpl against the real r/gov/dao, for the transfer
// app; see the core's z14f.
func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), member)
	testing.SetOriginCaller(member)

	testing.SetRealm(testing.NewCodeRealm(v99Path))
	transfer.RegisterImpl(cross(cur), newV99)

	testing.SetRealm(testing.NewUserRealm(member))
	req := transfer.NewUpdateImplProposalRequest(cross(cur), v99Path)
	pid := dao.MustCreateProposal(cross(cur), req)
	println("proposal:", pid, "-", req.Title())
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))

	println("before:", transfer.ImplPath(), transfer.ImplVersion())
	println("executed:", dao.ExecuteProposal(cross(cur), pid))
	println("after:", transfer.ImplPath(), transfer.ImplVersion())
}

// Output:
// proposal: 0000000 - gno.land/r/aib/ibc/apps/transfer: update implementation to gno.land/r/aib/ibc/apps/transfer/impl/v99
// before: gno.land/r/aib/ibc/apps/transfer/impl/v0 v0
// executed: true
// after: gno.land/r/aib/ibc/apps/transfer/impl/v99 v99

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
//         "value": "gno.land/r/aib/ibc/apps/transfer/impl/v0"
//       },
//       {
//         "key": "new_path",
//         "value": "gno.land/r/aib/ibc/apps/transfer/impl/v99"
//       },
//       {
//         "key": "version",
//         "value": "v99"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
