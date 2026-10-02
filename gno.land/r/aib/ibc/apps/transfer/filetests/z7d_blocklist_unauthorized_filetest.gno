// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/apps/transfer"

// BlockAddress is admin-only.
func main(cur realm) {
	transfer.SetAdmin(cross(cur), "g1someother00000000000000000000000000")
	transfer.BlockAddress(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
}

// Error:
// unauthorized: caller g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm is not the admin
