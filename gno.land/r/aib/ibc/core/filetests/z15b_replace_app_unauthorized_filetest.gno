// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// ReplaceApp is reserved to the authority, even for the realm being replaced.
func main(cur realm) {
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	successor := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/successor"))
	core.RegisterApp(cross(cur), "app1", successor)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.ReplaceApp(cross(cur), "app1", "gno.land/r/third/party/successor")
}

// Error:
// replace_app: caller g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9 is not a member of the authority
