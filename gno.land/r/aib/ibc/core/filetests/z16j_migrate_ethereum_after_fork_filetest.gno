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

// A fork-schedule migration of an Active client keeps the forks it verified
// updates under and may schedule one that activated since, before the block
// time: the client applied the ERC20 fixture's first update (finalized slot
// 128, signature slot 145: epochs 16 to 18); at slot 300 (epoch 37) Gloas is
// scheduled at epoch 30, and the client verifies its next update (signature
// slot 209, epoch 26) under the new schedule.
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
	verified := cs.ForkParameters
	verified.Fulu.Version[0]++
	println("verified fork:", core.MigrateClient(cross(cur), id, implv1.MigrationEthereumForkSchedule, ethereum.EncodeForkParameters(verified)))
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
// verified fork: the schedule changes a fork the client verified updates under (epochs 16 to 18)
// gloas at epoch 30: migrated
// updated: Active 0/192
