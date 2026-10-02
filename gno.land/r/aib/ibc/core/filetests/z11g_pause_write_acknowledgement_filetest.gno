// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// WriteAcknowledgement is rejected while paused.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.Pause(cross(cur))
	core.WriteAcknowledgement(cross(cur), "07-tendermint-1", 1, types.Acknowledgement{})
}

// Error:
// core is paused
