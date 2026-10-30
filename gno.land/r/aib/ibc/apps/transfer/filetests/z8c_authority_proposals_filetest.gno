// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// The tightening operation has a GovDAO proposal constructor; building it
// needs no privilege. Loosening operations are ibcgov decisions.
func main(cur realm) {
	const addr = "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"
	_ = transfer.NewBlockAddressProposalRequest(cross(cur), addr)
	println("ok")
}

// Output:
// ok
