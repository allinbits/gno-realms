// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"

	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Render home warns about open relaying only while the relayer whitelist is
// empty.
func main(cur realm) {
	println("open relaying, empty whitelist:", strings.Contains(core.Render(""), "**Open relaying**"))

	core.AddAuthorityMember(cross(cur), cur.Address())
	core.AddRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	println("open relaying, one relayer:", strings.Contains(core.Render(""), "**Open relaying**"))
}

// Output:
// open relaying, empty whitelist: true
// open relaying, one relayer: false
