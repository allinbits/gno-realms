// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// ApproveApp fails when nothing is pending for that port and realm.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.ApproveApp(cross(cur), "thirdparty", "gno.land/r/third/party/app")
}

// Error:
// no pending registration of gno.land/r/third/party/app for port thirdparty
