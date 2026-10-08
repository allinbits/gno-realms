// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/r/aib/ibc/apps/transfer"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

const v99Path = "gno.land/r/aib/ibc/apps/transfer/impl/v99"

type v99 struct{ transfer.Logic }

func (v99) Version() string { return "v99" }

func newV99(s transfer.Store) transfer.Logic { return v99{Logic: implv0.New(s)} }

// RegisterImpl refuses a realm outside the proxy's impl namespace.
func main(cur realm) {
	_ = testing.SetRealm
	transfer.RegisterImpl(cross(cur), newV99)
}

// Error:
// RegisterImpl: caller gno.land/r/aib/main is not under gno.land/r/aib/ibc/apps/transfer/impl/
