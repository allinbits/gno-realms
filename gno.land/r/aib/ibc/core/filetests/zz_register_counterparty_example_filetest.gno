// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
)

func main(cur realm) {
	var (
		clientID                 = "" // XXX update
		counterpartyMerklePrefix = [][]byte{
			[]byte("iavlStoreKey"), // XXX update
			[]byte("storeKey"),     // XXX update
		}
		counterpartyClientID = "" // XXX update
	)
	core.RegisterCounterparty(cross(cur), clientID, counterpartyMerklePrefix, counterpartyClientID)
}

// Error:
// invalid counterparty client id
