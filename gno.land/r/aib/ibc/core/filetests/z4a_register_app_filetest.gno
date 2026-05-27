// PKGPATH: gno.land/r/aib/main
package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// RegisterApp success
func main(cur realm) {
	core.RegisterApp(cross(cur), "app1", appstesting.NewApp(cross(cur)))
	core.RegisterApp(cross(cur), "app2", appstesting.NewApp(cross(cur)))

	println("----------- assert render apps")
	println(core.Render("apps"))
}

// Output:
// ----------- assert render apps
// [{"port_id":"app1","pkg_path":"gno.land/r/aib/main","address":"g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"},{"port_id":"app2","pkg_path":"gno.land/r/aib/main","address":"g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"}]
