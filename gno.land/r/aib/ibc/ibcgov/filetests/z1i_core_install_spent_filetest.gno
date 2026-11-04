// PKGPATH: gno.land/r/aib/ibc/core/impl/v99
package impl

import (
	"testing"
	"time"

	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const (
	self = "gno.land/r/aib/ibc/core/impl/v99"
	v98  = "gno.land/r/aib/ibc/core/impl/v98"
)

// logic is a rehearsal implementation: v0's logic under another version.
type logic struct {
	core.Logic
	ver string
}

func (l logic) Version() string { return l.ver }

func New(s core.Store) core.Logic { return logic{Logic: implv0.New(s), ver: "v99"} }

func init(cur realm) { core.RegisterImpl(cross(cur), New, "v99", nil) }

// registerV98 registers v98, whose manifest installs over v0 alone.
func registerV98(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(v98))
	core.RegisterImpl(cross(cur), func(s core.Store) core.Logic { return logic{Logic: implv0.New(s), ver: "v98"} }, "v98", []string{"v0"})
	testing.SetRealm(testing.NewCodeRealm(self))
}

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

// A core implementation switch whose candidate's manifest does not install
// over the active implementation is refused and spent when it executes
// (Codex round 4 #6, class B): after a rollback that would make it
// installable, its old approval never applies.
func main(cur realm) {
	registerV98(cur)
	toV98 := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), v98))
	toV99 := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), self))
	advance()
	ibcgov.Execute(cross(cur), toV99)
	println("active:", core.ImplVersion())
	ibcgov.Execute(cross(cur), toV98)
	println("v98 over v99:", decided(toV98))
	back := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v0"))
	advance()
	ibcgov.Execute(cross(cur), back)
	println("active:", core.ImplVersion())
	println("retry:", revive(func() { ibcgov.Execute(cross(cur), toV98) }))
	println("active:", core.ImplVersion())
}

// Output:
// active: v99
// v98 over v99: spent - spent: core impl v98 cannot install over version v99
// active: v0
// retry: ibcgov: decision 1 is spent, not pending
// active: v0
