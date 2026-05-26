// PKGPATH: gno.land/r/aib/main
package main

import (
	stdtesting "testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// RegisterApp fail because caller is not a realm
func main(cur realm) {
	stdtesting.SetRealm(stdtesting.NewUserRealm("g1user"))
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
}

// Error:
// RegisterApp can only be called from an other realm
