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

var member address = unsafe.OriginCaller()

// A passed proposal executed before the candidate registered: the proxy
// panics, the execution transaction aborts, and the proposal stays
// executable once the candidate is deployed.
func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), member)
	testing.SetOriginCaller(member)
	testing.SetRealm(testing.NewUserRealm(member))

	pid := dao.MustCreateProposal(cross(cur), core.NewUpdateImplProposalRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v99"))
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))
	dao.ExecuteProposal(cross(cur), pid)
}

// Error:
// no implementation registered at gno.land/r/aib/ibc/core/impl/v99
