// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// A pending registration cannot be approved once a trusted app took the port
// in the meantime: pending entries never reserve a port.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	foreign := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/app"))
	core.RegisterApp(cross(cur), "app1", foreign)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur))) // trusted: active at once
	core.ApproveApp(cross(cur), "app1", "gno.land/r/third/party/app")
}

// Error:
// portID app1 has already been registered
