package main

import (
	"gno.land/r/aib/ibc/core"
)

// Render admin page
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	println("=== no relayers ===")
	println(core.Render("admin"))
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1someother00000000000000000000000000")
	println("=== with relayers ===")
	println(core.Render("admin"))
	core.RemoveRelayer(cross, "g1someother00000000000000000000000000")
	println("=== after remove one relayer ===")
	println(core.Render("admin"))
}

// Output:
// === no relayers ===
// ## Admin & Relayers
//
// - **Admin**: [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
// - **Relayers**: any (whitelist empty)
//
// === with relayers ===
// ## Admin & Relayers
//
// - **Admin**: [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
// - **Relayers**:
//   - [g1some…0000](/u/g1someother00000000000000000000000000)
//   - [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
//
// === after remove one relayer ===
// ## Admin & Relayers
//
// - **Admin**: [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
// - **Relayers**:
//   - [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm)
