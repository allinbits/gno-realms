// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	implv1 "gno.land/r/aib/ibc/core/impl/v1"
)

// atSlot sets the block time to the fixture chain's slot.
func atSlot(slot uint64) {
	cs := ethtesting.ClientState()
	testing.SetContext(testing.Context{Time: time.Unix(int64(cs.GenesisTime+slot*cs.SecondsPerSlot), 0)})
}

// A fork-schedule migration of an Active client may schedule a fork that
// activated since, before the block time: the client applied the ERC20
// fixture's first update; at slot 300 (epoch 37) Gloas is scheduled at epoch
// 30, and the client verifies its next update (signature slot 209, epoch 26)
// under the new schedule. A schedule changing the genesis fork is refused.
func main(cur realm) {
	cs := ethtesting.ClientState()
	ups := ethtesting.ERC20Updates()
	id := core.CreateClient(cross(cur), cs, ethtesting.ERC20ConsensusState())
	atSlot(146)
	core.UpdateClient(cross(cur), id, ups[0])
	println("updated:", core.ClientStatus(id), core.ClientLatestHeight(id))

	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.UpdateImpl(cross(cur), "gno.land/r/aib/ibc/core/impl/v1")
	atSlot(300)
	genesis := cs.ForkParameters
	genesis.GenesisForkVersion[0]++
	println("genesis fork:", core.MigrateClient(cross(cur), id, implv1.MigrationEthereumForkSchedule, ethereum.EncodeForkParameters(genesis)))
	fp := cs.ForkParameters
	fp.Gloas = ethereum.Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 30}
	if refusal := core.MigrateClient(cross(cur), id, implv1.MigrationEthereumForkSchedule, ethereum.EncodeForkParameters(fp)); refusal == "" {
		println("gloas at epoch 30: migrated")
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	core.UpdateClient(cross(cur), id, ups[1])
	println("updated:", core.ClientStatus(id), core.ClientLatestHeight(id))
}

// Output:
// updated: Active 0/128
// genesis fork: the genesis fork version and slot cannot change
// gloas at epoch 30: migrated
// updated: Active 0/192
