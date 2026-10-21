// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// ReplaceApp only applies to an active port: a pending registration for a free
// port is activated with ApproveApp.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	app := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/app"))
	core.RegisterApp(cross(cur), "app1", app)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.ReplaceApp(cross(cur), "app1", "gno.land/r/third/party/app")
}

// Error:
// no registered app for port app1
