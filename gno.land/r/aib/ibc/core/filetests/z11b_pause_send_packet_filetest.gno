// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// SendPacket is rejected while paused.
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.Pause(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.SendPacket(cross(cur), types.MsgSendPacket{})
}

// Error:
// core is paused
