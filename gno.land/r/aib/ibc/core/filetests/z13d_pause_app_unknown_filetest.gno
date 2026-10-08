// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// PauseApp fails for a port with no registered app.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.PauseApp(cross(cur), "nope")
}

// Error:
// no registered app for port nope
