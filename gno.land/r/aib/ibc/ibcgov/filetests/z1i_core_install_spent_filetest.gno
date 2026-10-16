// PKGPATH: gno.land/r/aib/ibc/core/impl/v99
package impl

import (
	"testing"
	"time"

	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v1"
	"gno.land/r/aib/ibc/ibcgov"
)

const self = "gno.land/r/aib/ibc/core/impl/v99"

// logic is a rehearsal implementation: v0's logic under version v99, which
// core impl/v1 refuses as its predecessor.
type logic struct{ core.Logic }

func (logic) Version() string { return "v99" }

func New(s core.Store) core.Logic { return logic{Logic: implv0.New(s)} }

func init(cur realm) { core.RegisterImpl(cross(cur), New) }

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

// A core implementation switch whose candidate refuses the active
// implementation as its predecessor is refused and spent when it executes
// (Codex round 4 #6, class B): after a rollback that would make it
// installable, its old approval never applies.
func main(cur realm) {
	toV1 := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v1"))
	toV99 := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), self))
	advance()
	ibcgov.Execute(cross(cur), toV99)
	println("active:", core.ImplVersion())
	ibcgov.Execute(cross(cur), toV1)
	println("v1 over v99:", decided(toV1))
	back := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v0"))
	advance()
	ibcgov.Execute(cross(cur), back)
	println("active:", core.ImplVersion())
	println("retry:", revive(func() { ibcgov.Execute(cross(cur), toV1) }))
	println("active:", core.ImplVersion())
}

// Output:
// active: v99
// v1 over v99: spent - spent: core impl v1 cannot install over version v99
// active: v0
// retry: ibcgov: decision 1 is spent, not pending
// active: v0
