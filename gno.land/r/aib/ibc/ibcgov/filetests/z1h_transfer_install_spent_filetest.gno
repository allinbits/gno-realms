// PKGPATH: gno.land/r/aib/ibc/apps/transfer/impl/v99
package impl

import (
	"errors"
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

// logic is a rehearsal implementation: v0's logic, without the route
// controls, under version v99; while refuseV1 holds, it refuses impl/v1 as
// its predecessor.
type logic struct{ transfer.Logic }

var refuseV1 = true

func (logic) Version() string { return "v99" }

func (logic) CheckInstall(prevPath, prevVersion string) error {
	if refuseV1 && prevVersion == "v1" {
		return errors.New("transfer impl v99 cannot install over version v1")
	}
	return nil
}

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

// The transfer app starts with impl/v1 (a fresh deployment). A switch whose
// candidate refuses the active implementation as its predecessor is refused
// and spent when it executes (Codex round 4 #6, class B), never retried.
// Once an Ethereum route exists, an implementation without the route
// controls is refused, whatever its own checks.
func main(cur realm) {
	println("active:", transfer.ImplVersion())
	toV99 := govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), self))
	advance()
	ibcgov.Execute(cross(cur), toV99)
	println("v99 over v1:", decided(toV99), "| active:", transfer.ImplVersion())
	println("retry:", revive(func() { ibcgov.Execute(cross(cur), toV99) }))

	refuseV1 = false
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	enroll := govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(testutils.TestAddress("collector")), bridge))
	advance()
	ibcgov.Execute(cross(cur), enroll)
	again := govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), self))
	advance()
	ibcgov.Execute(cross(cur), again)
	println("v99 once a route exists:", decided(again), "| active:", transfer.ImplVersion())
	same := govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1"))
	advance()
	ibcgov.Execute(cross(cur), same)
	println("v1 reinstalled:", decided(same))
}

// Output:
// active: v1
// v99 over v1: spent - spent: transfer impl v99 cannot install over version v1 | active: v1
// retry: ibcgov: decision 1 is spent, not pending
// v99 once a route exists: spent - spent: transfer: an implementation without the route controls cannot replace them once a route has them | active: v1
// v1 reinstalled: applied - transfer update impl
