// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v99"
)

// Loaded after v0, the candidate registers and activates nothing.
func main(cur realm) {
	println("registered:", core.RegisteredImplPaths())
	println("active:", core.ImplPath(), core.ImplVersion())
}

// Output:
// registered: slice[("gno.land/r/aib/ibc/core/impl/v0" string),("gno.land/r/aib/ibc/core/impl/v99" string)]
// active: gno.land/r/aib/ibc/core/impl/v0 v0
