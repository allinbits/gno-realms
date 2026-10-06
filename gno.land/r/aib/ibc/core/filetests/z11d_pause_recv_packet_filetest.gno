// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
)

// RecvPacket is rejected while paused.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.Pause(cross(cur))
	core.RecvPacket(cross(cur), types.MsgRecvPacket{})
}

// Error:
// core is paused
