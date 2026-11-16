// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// WriteAcknowledgement is rejected while paused.
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.Pause(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.WriteAcknowledgement(cross(cur), "07-tendermint-1", 1, types.Acknowledgement{})
}

// Error:
// core is paused
