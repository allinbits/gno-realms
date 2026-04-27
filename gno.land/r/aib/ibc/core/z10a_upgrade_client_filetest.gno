package main

// PKGPATH: gno.land/r/aib/main

import (
	"gno.land/r/aib/ibc/core"
)

// UpgradeClient failure: client not found
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")

	core.UpgradeClient(cross, "07-tendermint-99", nil, nil, nil, nil)
}

// Error:
// client 07-tendermint-99 not found
