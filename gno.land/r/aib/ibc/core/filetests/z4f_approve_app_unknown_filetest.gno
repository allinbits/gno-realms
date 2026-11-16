// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// ApproveApp fails when nothing is pending for that port and realm.
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.ApproveApp(cross(cur), "thirdparty", "gno.land/r/third/party/app")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// Error:
// no pending registration of gno.land/r/third/party/app for port thirdparty
