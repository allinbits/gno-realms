// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// A registration for a port that is already active is only queued, and
// ApproveApp cannot activate it: taking an active port is ReplaceApp's job.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	foreign := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/app"))
	core.RegisterApp(cross(cur), "app1", foreign)
	println("pending:", core.IsAppPending("app1", "gno.land/r/third/party/app"))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.ApproveApp(cross(cur), "app1", "gno.land/r/third/party/app")
}

// Output:
// pending: true

// Error:
// portID app1 has already been registered
