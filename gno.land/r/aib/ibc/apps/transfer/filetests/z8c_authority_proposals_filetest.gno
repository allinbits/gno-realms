// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Every gated operation has a GovDAO proposal constructor.
func main(cur realm) {
	const addr = "g1someother00000000000000000000000000"
	_ = transfer.NewBlockAddressProposalRequest(cross(cur), addr)
	_ = transfer.NewUnblockAddressProposalRequest(cross(cur), addr)
	_ = transfer.NewAddAuthorityMemberProposalRequest(cross(cur), addr)
	_ = transfer.NewRemoveAuthorityMemberProposalRequest(cross(cur), addr)
	_ = transfer.NewUpdateImplProposalRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1")
	println("ok")
}

// Output:
// ok
