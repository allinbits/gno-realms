// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// SendPacket assert that MsgSendPacket.ValidateBasic is invoked
func main(cur realm) {
	packet := types.MsgSendPacket{}
	core.SendPacket(cross(cur), packet)
}

// Error:
// validate client identifier: identifier cannot be blank
