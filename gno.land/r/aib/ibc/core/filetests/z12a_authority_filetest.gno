// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/p/aib/authority/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Authority (ADR pr6375 R14): the members are fixed at init to the GovDAO
// proxy and the ibcgov realm, with no deployer. The loosening operations
// (relayers, membership, unpausing, upgrades) are ibcgov's alone; GovDAO keeps
// the immediate tightening ones (Pause, PauseApp, RejectApp).
func main(cur realm) {
	govdao := chain.PackageAddress(authority.GovDAOPath)
	ibcgov := chain.PackageAddress(core.IBCGovPath)
	println("govdao member:", core.IsAuthorityMember(govdao))
	println("ibcgov member:", core.IsAuthorityMember(ibcgov))
	println("main member:  ", core.IsAuthorityMember(cur.Address()))

	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.AddRelayer(cross(cur), "g1relayer000000000000000000000000000000")
	core.AddAuthorityMember(cross(cur), "g1someother00000000000000000000000000")
	println(core.Render("admin"))
	core.RemoveRelayer(cross(cur), "g1relayer000000000000000000000000000000")
	core.RemoveAuthorityMember(cross(cur), "g1someother00000000000000000000000000")

	// GovDAO pauses at once, but resuming is ibcgov's.
	testing.SetRealm(testing.NewCodeRealm(authority.GovDAOPath))
	core.Pause(cross(cur))
	println("paused:", core.Paused())
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.Unpause(cross(cur))
	println("paused:", core.Paused())
}

// Output:
// govdao member: true
// ibcgov member: true
// main member:   false
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g12l3d…fay4](/u/g12l3du5z70zzq9rkc82asre09srefve7p5mfay4)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
//   - [g1some…0000](/u/g1someother00000000000000000000000000)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
//   - [`gno.land/r/aib/ibc/core/impl/v1`](/r/aib/ibc/core/impl/v1)
// - **Relayers**:
//   - [g1rela…0000](/u/g1relayer000000000000000000000000000000)
//
// paused: true
// paused: false

// Events:
// [
//   {
//     "type": "authority_member_added",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1someother00000000000000000000000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "authority_member_removed",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1someother00000000000000000000000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "pause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "unpause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
