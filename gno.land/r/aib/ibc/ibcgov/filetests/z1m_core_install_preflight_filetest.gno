// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const drifting = "gno.land/r/aib/ibc/core/impl/v77"

// driftingLogic is v0's logic under the active version, whatever its
// manifest declares.
type driftingLogic struct{ core.Logic }

func (driftingLogic) Version() string { return core.ImplVersion() }

func register(cur realm, path, version string, ctor func(core.Store) core.Logic) {
	testing.SetRealm(testing.NewCodeRealm(path))
	core.RegisterImpl(cross(cur), ctor, version, nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
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

// The preflight of an implementation switch reads the candidate's manifest
// and never builds it (review of #91): candidate code runs once, in the
// authorized installation. A candidate whose constructor builds another
// version than its manifest declares passes the preflight, and its
// installation aborts and rolls back: the decision stays pending, with
// nothing changed, until a cancel decision withdraws it.
func main(cur realm) {
	// v77 declares v1 but builds whatever version is active.
	register(cur, drifting, "v1", func(s core.Store) core.Logic { return driftingLogic{Logic: implv0.New(s)} })
	println("active:", core.ImplVersion(), "| preflight:", core.CheckUpdateImpl(drifting) == "")

	drift := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), drifting))
	advance()
	println("install:", revive(func() { ibcgov.Execute(cross(cur), drift) }))
	println("v77:", decided(drift), "| active:", core.ImplVersion())

	govern(cur, ibcgov.NewCancelRequest(cross(cur), drift))
	println("cancelled:", decided(drift))
	println("retry:", revive(func() { ibcgov.Execute(cross(cur), drift) }), "| active:", core.ImplVersion())
}

// Output:
// active: v0 | preflight: true
// install: implementation gno.land/r/aib/ibc/core/impl/v77 declared version v1, not v0
// v77: pending - queued 7 days | active: v0
// cancelled: cancelled - queued 7 days
// retry: ibcgov: decision 1 is cancelled, not pending | active: v0
