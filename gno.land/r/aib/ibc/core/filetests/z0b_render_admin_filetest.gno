// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Render admin page
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	println("=== no relayers ===")
	println(core.Render("admin"))
	core.AddRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross(cur), "g1someother00000000000000000000000000")
	println("=== with relayers ===")
	println(core.Render("admin"))
	core.RemoveRelayer(cross(cur), "g1someother00000000000000000000000000")
	println("=== after remove one relayer ===")
	println(core.Render("admin"))
}

// Output:
// === no relayers ===
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g1gjs8…qxd9](/u/g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
// - **Relayers**: any (whitelist empty)
//
// === with relayers ===
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g1gjs8…qxd9](/u/g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
// - **Relayers**:
//   - [g1some…0000](/u/g1someother00000000000000000000000000)
//   - [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
//
// === after remove one relayer ===
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g1gjs8…qxd9](/u/g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
// - **Relayers**:
//   - [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
