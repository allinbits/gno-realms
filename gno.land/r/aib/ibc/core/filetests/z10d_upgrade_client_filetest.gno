// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// UpgradeClient failure: malformed clientID rejected by host.ClientIdentifierValidator
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.AddRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")

	core.UpgradeClient(cross(cur), "abc!@#", nil, nil, nil, nil)
}

// Error:
// validate client identifier: identifier abc!@# must contain only alphanumeric or the following characters: '.', '_', '+', '-', '#', '[', ']', '<', '>'
