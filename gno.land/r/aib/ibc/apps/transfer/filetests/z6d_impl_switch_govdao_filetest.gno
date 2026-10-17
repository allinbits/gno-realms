// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/runtime/unsafe"
	"testing"

	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/gov/dao"
	daoinit "gno.land/r/gov/dao/init/v0"
)

// member is a GovDAO T1 member, not a member of the transfer authority.
var member address = unsafe.OriginCaller()

// The GovDAO path of the transfer app's tightening operation against the real
// r/gov/dao; see the core's z14f. An upgrade is not on this path: it is an
// ibcgov decision.
func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), member)
	testing.SetOriginCaller(member)
	testing.SetRealm(testing.NewUserRealm(member))

	const blockee = "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"
	req := transfer.NewBlockAddressProposalRequest(cross(cur), blockee)
	pid := dao.MustCreateProposal(cross(cur), req)
	println("proposal:", pid, "-", req.Title())
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))

	println("before:", transfer.IsBlocked(blockee))
	println("executed:", dao.ExecuteProposal(cross(cur), pid))
	println("after:", transfer.IsBlocked(blockee))
}

// Output:
// proposal: 0000000 - gno.land/r/aib/ibc/apps/transfer: block address g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx
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
//     "type": "block",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
