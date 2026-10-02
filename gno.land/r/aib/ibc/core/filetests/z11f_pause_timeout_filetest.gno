// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// Timeout is rejected while paused.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.Pause(cross(cur))
	core.Timeout(cross(cur), types.MsgTimeout{})
}

// Error:
// core is paused
