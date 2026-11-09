// PKGPATH: gno.land/r/aib/main
package main

import (
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// An Ethereum client's consensus states are listed, paginated, like a
// Tendermint client's, and each is still served by its height.
func main(cur realm) {
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	println(core.Render("clients/" + id + "/consensus_states"))
	println(core.Render("clients/" + id + "/consensus_states/0/72"))
}

// Output:
// {"items":[{"height":{"revision_number":0,"revision_height":72},"slot":72,"timestamp":1234567800,"state_root":"q4lNCXiYYNW6M0L2Hrd/aBZJ0CJSzBwCYPwO83mVBIE=","current_sync_committee":{"pubkeys_hash":"Iqn/CGyjxIVK0GKMgWoV/IcY1+/JspOvKlrHHVS0sU8=","aggregate_pubkey":"uSh4ZTA79IGqgNfyUBJ7sLIoGf9oGgImJoDTHnE0+1MX9VMcX4QkRkG2ku7xvRUc"},"next_sync_committee_known":false}],"page":1,"total":1}
// {"height":{"revision_number":0,"revision_height":72},"slot":72,"timestamp":1234567800,"state_root":"q4lNCXiYYNW6M0L2Hrd/aBZJ0CJSzBwCYPwO83mVBIE=","current_sync_committee":{"pubkeys_hash":"Iqn/CGyjxIVK0GKMgWoV/IcY1+/JspOvKlrHHVS0sU8=","aggregate_pubkey":"uSh4ZTA79IGqgNfyUBJ7sLIoGf9oGgImJoDTHnE0+1MX9VMcX4QkRkG2ku7xvRUc"},"next_sync_committee_known":false}
