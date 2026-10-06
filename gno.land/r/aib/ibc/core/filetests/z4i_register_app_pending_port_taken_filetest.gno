// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// A foreign realm cannot even queue a registration for a port that is already
// active.
func main(cur realm) {
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	foreign := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/app"))
	core.RegisterApp(cross(cur), "app1", foreign)
}

// Error:
// portID app1 has already been registered
