// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// WriteAcknowledgement is rejected while paused.
func main(cur realm) {
	core.SetAdmin(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.Pause(cross(cur))
	core.WriteAcknowledgement(cross(cur), "07-tendermint-1", 1, types.Acknowledgement{})
}

// Error:
// core is paused
