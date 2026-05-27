// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// RegisterApp fails because portID is not alphanumeric
func main(cur realm) {
	core.RegisterApp(cross(cur), "gno.land/r/aib/ibc", appstesting.NewApp(cross(cur)))
}

// Error:
// invalid portID: validate port identifier: identifier gno.land/r/aib/ibc cannot contain separator '/'
