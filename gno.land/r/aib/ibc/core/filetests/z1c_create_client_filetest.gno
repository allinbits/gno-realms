// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
)

// RegisterCounterparty w/o existing client
func main(cur realm) {
	core.RegisterCounterparty(cross(cur), "unknown-client", [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")
}

// Error:
// client unknown-client not found
