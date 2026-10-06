// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// The exported Emit* wrappers (and the store mutators, gated the same way)
// refuse any realm value but the proxy's own live cur: a foreign realm cannot
// forge IBC events under the core pkg_path.
func main(cur realm) {
	core.EmitSendPacket(0, cur, types.Packet{})
}

// Error:
// core: access denied for non-proxy realm gno.land/r/aib/main
