// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Render admin page
func main(cur realm) {
	println("=== no relayers ===")
	println(core.Render("admin"))
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.AddRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross(cur), "g1someother00000000000000000000000000")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("=== with relayers ===")
	println(core.Render("admin"))
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath)) // decided by the governance realm
	core.RemoveRelayer(cross(cur), "g1someother00000000000000000000000000")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("=== after remove one relayer ===")
	println(core.Render("admin"))
}

// Output:
// === no relayers ===
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g12l3d…fay4](/u/g12l3du5z70zzq9rkc82asre09srefve7p5mfay4)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
//   - [`gno.land/r/aib/ibc/core/impl/v1`](/r/aib/ibc/core/impl/v1)
// - **Relayers**: any (whitelist empty)
//
// === with relayers ===
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g12l3d…fay4](/u/g12l3du5z70zzq9rkc82asre09srefve7p5mfay4)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
//   - [`gno.land/r/aib/ibc/core/impl/v1`](/r/aib/ibc/core/impl/v1)
// - **Relayers**:
//   - [g1some…0000](/u/g1someother00000000000000000000000000)
//   - [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
//
// === after remove one relayer ===
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g12l3d…fay4](/u/g12l3du5z70zzq9rkc82asre09srefve7p5mfay4)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
//   - [`gno.land/r/aib/ibc/core/impl/v1`](/r/aib/ibc/core/impl/v1)
// - **Relayers**:
//   - [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
