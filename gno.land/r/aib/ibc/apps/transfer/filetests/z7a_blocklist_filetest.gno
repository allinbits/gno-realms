// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Block / unblock round trip by the governance realm (unblocking is its
// decision alone); the admin page lists the blocklist.
func main(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(transfer.IBCGovPath)) // decided by the governance realm
	println("blocked:", transfer.IsBlocked("g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"))
	transfer.BlockAddress(cross(cur), "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx")
	println("blocked:", transfer.IsBlocked("g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"))
	println(transfer.Render("admin"))
	transfer.UnblockAddress(cross(cur), "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx")
	println("blocked:", transfer.IsBlocked("g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"))
	println(transfer.Render("admin"))
}

// Output:
// blocked: false
// blocked: true
// ## Authority
//
// - **Authority members**:
//   - g12l3du5z70zzq9rkc82asre09srefve7p5mfay4
//   - g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r
// - **Paused**: false (set by the IBC core)
// - **Implementation**: [`gno.land/r/aib/ibc/apps/transfer/impl/v1`](/r/aib/ibc/apps/transfer/impl/v1) (version v1)
// - **Registered implementations**:
//   - gno.land/r/aib/ibc/apps/transfer/impl/v1
// - **Blocked addresses**:
//   - g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx
//
// blocked: false
// ## Authority
//
// - **Authority members**:
//   - g12l3du5z70zzq9rkc82asre09srefve7p5mfay4
//   - g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r
// - **Paused**: false (set by the IBC core)
// - **Implementation**: [`gno.land/r/aib/ibc/apps/transfer/impl/v1`](/r/aib/ibc/apps/transfer/impl/v1) (version v1)
// - **Registered implementations**:
//   - gno.land/r/aib/ibc/apps/transfer/impl/v1
// - **Blocked addresses**: none

// Events:
// [
//   {
//     "type": "block",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "unblock",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1wdhk6et0w35x2ujlta047h6lta047h6l82cvgx"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
