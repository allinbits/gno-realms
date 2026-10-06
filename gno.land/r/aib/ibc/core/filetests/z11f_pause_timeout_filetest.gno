// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Timeout is rejected while paused.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.Pause(cross(cur))
	core.Timeout(cross(cur), types.MsgTimeout{})
}

// Error:
// core is paused
