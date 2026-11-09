// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Every tightening operation has a GovDAO proposal constructor; building the
// requests needs no privilege (creating the proposal is GovDAO's job). The
// loosening operations have none: they are ibcgov decisions.
func main(cur realm) {
	_ = core.NewPauseProposalRequest(cross(cur))
	_ = core.NewPauseAppProposalRequest(cross(cur), "transfer")
	_ = core.NewRejectAppProposalRequest(cross(cur), "thirdparty", "gno.land/r/third/party/app")
	println("ok")
}

// Output:
// ok
