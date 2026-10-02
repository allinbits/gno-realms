// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// RecvPacket is rejected while paused.
func main(cur realm) {
	core.SetAdmin(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.Pause(cross(cur))
	core.RecvPacket(cross(cur), types.MsgRecvPacket{})
}

// Error:
// core is paused
