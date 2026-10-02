// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/core"

// A non-member cannot administer the realm. The bootstrap admits a stranger;
// this realm is then not a member.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), "g1someother00000000000000000000000000")
	core.AddRelayer(cross(cur), "g1relayer000000000000000000000000000000")
}

// Error:
// add_relayer: caller g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9 is not a member of the authority
