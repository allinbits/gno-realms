// PKGPATH: gno.land/r/aib/ibc/apps/transfer/impl/v99
package impl

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

const self = "gno.land/r/aib/ibc/apps/transfer/impl/v99"

// logic is a rehearsal implementation: v0's logic under version v99, which
// transfer impl/v1 refuses as its predecessor.
type logic struct{ transfer.Logic }

func (logic) Version() string { return "v99" }

func New(s transfer.Store) transfer.Logic { return logic{Logic: implv0.New(s)} }

func init(cur realm) { transfer.RegisterImpl(cross(cur), New) }

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm(self))
	return ibcgov.LastDecision()
}

func advance() {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(7*24*time.Hour + time.Second)
	testing.SetContext(ctx)
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// A transfer implementation switch whose candidate refuses the active
// implementation as its predecessor is refused and spent when it executes
// (Codex round 4 #6, class B): after a rollback that would make it
// installable, its old approval never applies. The first implementation with
// the route controls installs only through the staged activation, never the
// ordinary switch (Codex round 6 #4); once it is active, the ordinary switch
// reinstalls it.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	activate := func() ibcgov.Request {
		return ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", client,
			string(testutils.TestAddress("collector")), bridge, "", "", 10_000)
	}
	toV1 := govern(cur, activate())
	toV99 := govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), self))
	advance()
	ibcgov.Execute(cross(cur), toV99)
	println("active:", transfer.ImplVersion())
	ibcgov.Execute(cross(cur), toV1)
	println("v1 over v99:", decided(toV1))
	back := govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v0"))
	advance()
	ibcgov.Execute(cross(cur), back)
	println("active:", transfer.ImplVersion())
	println("retry:", revive(func() { ibcgov.Execute(cross(cur), toV1) }))
	println("active:", transfer.ImplVersion())

	println("the ordinary switch to v1:", revive(func() {
		ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1")
	}))
	staged := govern(cur, activate())
	advance()
	ibcgov.Execute(cross(cur), staged)
	println("staged:", decided(staged))
	again := govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1"))
	advance()
	ibcgov.Execute(cross(cur), again)
	println("reinstalled by the ordinary switch:", decided(again), "| active:", transfer.ImplVersion())
}

// Output:
// active: v99
// v1 over v99: spent - spent: transfer impl v1 cannot install over version v99
// active: v0
// retry: ibcgov: decision 1 is spent, not pending
// active: v0
// the ordinary switch to v1: ibcgov: the route controls are first activated by a staged activation (NewTransferActivateControlsRequest), with their first route and legacy refund cap
// staged: applied - transfer gno.land/r/aib/ibc/apps/transfer/impl/v1 active with route ethereum-1 and 0 denoms
// reinstalled by the ordinary switch: applied - transfer update impl | active: v1
