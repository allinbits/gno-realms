// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/apps/transfer"

// Transfer is rejected while the app is paused.
func main(cur realm) {
	transfer.SetAdmin(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	transfer.Pause(cross(cur))
	transfer.Transfer(cross(cur), "07-tendermint-1", "atone1user", "ugnot", 100, 1, "")
}

// Error:
// transfer is paused
