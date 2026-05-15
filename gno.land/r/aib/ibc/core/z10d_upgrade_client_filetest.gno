package main

// PKGPATH: gno.land/r/aib/main

import (
	"gno.land/r/aib/ibc/core"
)

// UpgradeClient failure: malformed clientID rejected by host.ClientIdentifierValidator
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")

	core.UpgradeClient(cross, "abc!@#", nil, nil, nil, nil)
}

// Error:
// validate client identifier: identifier abc!@# must contain only alphanumeric or the following characters: '.', '_', '+', '-', '#', '[', ']', '<', '>'
