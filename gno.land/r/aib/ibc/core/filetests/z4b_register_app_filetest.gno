// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// RegisterApp error when already registered
func main(cur realm) {
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
}

// Error:
// portID app1 has already been registered
