// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/apps/transfer"

// A non-member cannot administer the realm.
func main(cur realm) {
	transfer.AddAuthorityMember(cross(cur), "g1someother00000000000000000000000000")
	transfer.Pause(cross(cur))
}

// Error:
// pause: caller g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9 is not a member of the authority
