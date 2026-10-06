// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
)

// SendPacket is rejected while paused.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.Pause(cross(cur))
	core.SendPacket(cross(cur), types.MsgSendPacket{})
}

// Error:
// core is paused
