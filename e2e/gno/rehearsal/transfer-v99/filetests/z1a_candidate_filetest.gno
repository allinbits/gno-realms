// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v99"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Loaded after v0, the candidate registers and activates nothing.
func main(cur realm) {
	println("registered:", transfer.RegisteredImplPaths())
	println("active:", transfer.ImplPath(), transfer.ImplVersion())
}

// Output:
// registered: slice[("gno.land/r/aib/ibc/apps/transfer/impl/v0" string),("gno.land/r/aib/ibc/apps/transfer/impl/v99" string)]
// active: gno.land/r/aib/ibc/apps/transfer/impl/v0 v0
