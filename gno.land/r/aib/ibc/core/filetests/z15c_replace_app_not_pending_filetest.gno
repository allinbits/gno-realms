// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// ReplaceApp needs the successor's pending registration: it carries the app
// value, which only the successor realm can provide.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	core.ReplaceApp(cross(cur), "app1", "gno.land/r/third/party/successor")
}

// Error:
// no pending registration of gno.land/r/third/party/successor for port app1
