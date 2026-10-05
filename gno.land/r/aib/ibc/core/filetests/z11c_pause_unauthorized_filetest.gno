// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/core"

// Pause is admin-only.
func main(cur realm) {
	core.SetAdmin(cross(cur), "g1someother00000000000000000000000000")
	core.Pause(cross(cur))
}

// Error:
// unauthorized: caller g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm is not the admin
