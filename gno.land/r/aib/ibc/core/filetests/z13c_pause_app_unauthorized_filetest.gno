// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// PauseApp is for authority members only.
func main(cur realm) {
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	core.AddAuthorityMember(cross(cur), "g1someother00000000000000000000000000")
	core.PauseApp(cross(cur), "app1")
}

// Error:
// pause_app: caller g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9 is not a member of the authority
