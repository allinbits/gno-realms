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

// UpdateImpl is reserved to the authority.
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(v99Path))
	transfer.RegisterImpl(cross(cur), newV99)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	transfer.UpdateImpl(cross(cur), v99Path)
}

// Error:
// update_impl: caller g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9 is not a member of the authority
