// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// atSlot sets the block time to the fixture chain's slot.
func atSlot(slot uint64) {
	cs := ethtesting.ClientState()
	testing.SetContext(testing.Context{Time: time.Unix(int64(cs.GenesisTime+slot*cs.SecondsPerSlot), 0)})
}

// An Ethereum client recovered through core's RecoverClient takes the
// substitute's fork schedule and verifies the next signed update under it.
// The subject is the ERC20 fixture's client at slot 72, expired; the
// substitute was created at slot 128 (the state the fixture's first update
// leads to) with Gloas scheduled at epoch 100.
func main(cur realm) {
	cs := ethtesting.ClientState()
	ups := ethtesting.ERC20Updates()
	subject := core.CreateClient(cross(cur), cs, ethtesting.ERC20ConsensusState())

	// The substitute's state: the fixture's state after its first update.
	local := ethereum.NewEthLightClient()
	if err := local.Initialize(cs, ethtesting.ERC20ConsensusState()); err != nil {
		panic(err)
	}
	local.UpdateState(ups[0])
	cons, _ := local.GetConsensusState(types.NewHeight(0, 128))
	subCS := *local.ClientState
	subCS.ForkParameters.Gloas = ethereum.Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 100}
	substitute := core.CreateClient(cross(cur), subCS, *cons)

	// Slot 600: the subject is 528 slots past its latest, beyond the 512-slot
	// window; the substitute, 472 past its own, within it.
	atSlot(600)
	println("subject:", core.ClientStatus(subject), "substitute:", core.ClientStatus(substitute))

	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.RecoverClient(cross(cur), subject, substitute)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("recovered:", core.ClientStatus(subject), core.ClientLatestHeight(subject))
	r := core.Render("clients/" + subject)
	i := strings.Index(r, `"gloas":`)
	println("schedule:", r[i:i+strings.Index(r[i:], "}")+1])

	core.UpdateClient(cross(cur), subject, ups[1])
	println("updated:", core.ClientStatus(subject), core.ClientLatestHeight(subject))
}

// Output:
// subject: Expired substitute: Active
// recovered: Active 0/128
// schedule: "gloas":{"version":"gAAAOA==","epoch":"100"}
// updated: Active 0/192
