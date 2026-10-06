// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Every gated operation has a GovDAO proposal constructor; building the
// requests needs no privilege (creating the proposal is GovDAO's job).
func main(cur realm) {
	const addr = "g1someother00000000000000000000000000"
	_ = core.NewAddRelayerProposalRequest(cross(cur), addr)
	_ = core.NewRemoveRelayerProposalRequest(cross(cur), addr)
	_ = core.NewRecoverClientProposalRequest(cross(cur), "07-tendermint-1", "07-tendermint-2")
	_ = core.NewPauseProposalRequest(cross(cur))
	_ = core.NewUnpauseProposalRequest(cross(cur))
	_ = core.NewAddAuthorityMemberProposalRequest(cross(cur), addr)
	_ = core.NewRemoveAuthorityMemberProposalRequest(cross(cur), addr)
	_ = core.NewUpdateImplProposalRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v1")
	println("ok")
}

// Output:
// ok
