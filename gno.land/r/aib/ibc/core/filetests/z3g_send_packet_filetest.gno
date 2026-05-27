// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// SendPacket assert that MsgSendPacket.ValidateBasic is invoked
func main(cur realm) {
	packet := types.MsgSendPacket{}
	core.SendPacket(cross(cur), packet)
}

// Error:
// validate client identifier: identifier cannot be blank
