// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// UnregisterApp of a free port is refused.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.UnregisterApp(cross(cur), "app1")
}

// Error:
// no registered app for port app1
