// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// A non-member cannot administer the realm.
func main(cur realm) {
	transfer.AddAuthorityMember(cross(cur), "g1someother00000000000000000000000000")
	transfer.BlockAddress(cross(cur), "g1someother00000000000000000000000000")
}

// Error:
// block_address: caller g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9 is not a member of the authority
