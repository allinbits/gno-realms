// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// PauseApp fails for a port with no registered app.
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.PauseApp(cross(cur), "nope")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// Error:
// no registered app for port nope
