// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/apps/transfer"

// Pause / Unpause round trip by the admin; the home page shows a banner while
// paused.
func main(cur realm) {
	transfer.AddAuthorityMember(cross(cur), cur.Address())
	println("paused:", transfer.Paused())
	transfer.Pause(cross(cur))
	println("paused:", transfer.Paused())
	println(transfer.Render(""))
	transfer.Unpause(cross(cur))
	println("paused:", transfer.Paused())
}

// Output:
// paused: false
// paused: true
// # IBC transfer
//
// ICS-20 style transfer state and voucher token queries.
//
// > **Paused**: transfers are suspended by the admin; incoming packets are refused.
//
// ## Transfer
//
// No IBC client registered yet — create one in [`/r/aib/ibc/core`](/r/aib/ibc/core) before transferring.
//
// ## Vouchers (0)
//
// No vouchers yet.
//
// ## Escrow (0)
//
// No escrow yet.
//
// ## JSON endpoints
//
// - [`admin`](/r/aib/ibc/apps/transfer:admin): authority, pause state, blocked addresses
// - [`denoms`](/r/aib/ibc/apps/transfer:denoms): list known IBC denoms (`?page`, `?limit`)
// - `denoms/ibc/{hash}`: get metadata for an IBC denom
// - `total_escrow/{denom}`: get total escrow tracked for a base denom
// - [`vouchers`](/r/aib/ibc/apps/transfer:vouchers): list voucher tokens (`?page`, `?limit`)
// - `voucher/ibc/{hash}`: get voucher token metadata
// - `voucher/ibc/{hash}/balance/{addr}`: get a voucher balance for an address
//
//
// paused: false

// Events:
// [
//   {
//     "type": "authority_member_added",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "pause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "unpause",
//     "attrs": [],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
