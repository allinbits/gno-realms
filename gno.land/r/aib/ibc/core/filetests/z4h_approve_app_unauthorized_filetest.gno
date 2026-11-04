// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// ApproveApp is a governance decision (ibcgov only).
func main(cur realm) {
	core.ApproveApp(cross(cur), "thirdparty", "gno.land/r/third/party/app")
}

// Error:
// approve_app: only gno.land/r/aib/ibc/ibcgov decides this, not gno.land/r/aib/main
