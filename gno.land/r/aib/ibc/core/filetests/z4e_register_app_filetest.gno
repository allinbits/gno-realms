// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// RegisterApp fails because the port is reserved for the transfer realm.
//
// Core is enabled before the transfer realm on a chain that enables packages
// one at a time, and a port is never freed, so without the reservation any
// realm could take "transfer" for good in between.
func main(cur realm) {
	core.RegisterApp(cross(cur), "transfer", appstesting.NewApp(cross(cur)))
}

// Error:
// portID transfer is reserved for gno.land/r/aib/ibc/apps/transfer
