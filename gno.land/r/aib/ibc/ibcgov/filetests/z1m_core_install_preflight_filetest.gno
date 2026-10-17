// PKGPATH: gno.land/r/aib/main
package main

import (
	"errors"
	"testing"
	"time"

	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
	implv1 "gno.land/r/aib/ibc/core/impl/v1"
	"gno.land/r/aib/ibc/ibcgov"
)

const (
	drifting = "gno.land/r/aib/ibc/core/impl/v77"
	picky    = "gno.land/r/aib/ibc/core/impl/v78"
)

// pickyLogic is v0's logic under v78, whose install hook refuses v1 as its
// predecessor, its check a pure function of the plain values the proxy
// passes.
type pickyLogic struct{ core.Logic }

func (pickyLogic) Version() string { return "v78" }

func (pickyLogic) CheckInstall(prevPath, prevVersion string) error {
	if prevVersion == "v1" {
		return errors.New("core impl v78 does not install over v1")
	}
	return nil
}

func (l pickyLogic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	if err := l.CheckInstall(prevPath, prevVersion); err != nil {
		panic(err)
	}
}

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

func execute(cur realm, id int64) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(7*24*time.Hour + time.Second)
	testing.SetContext(ctx)
	ibcgov.Execute(cross(cur), id)
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// The preflight of an implementation switch builds the candidate against an
// empty store and checks it before anything changes (Codex round 29): an
// implementation whose constructor builds another version than its manifest
// declares, or whose install hook refuses the active implementation, is
// refused and its decision spent, so the old approval cannot install it once
// the state that made it fail has changed.
func main(cur realm) {
	// v77 declares v1 but builds whatever version is active.
	register(cur, drifting, "v1", func(s core.Store) core.Logic {
		return implv1.NewWithConversions(s, core.ImplVersion(), nil, nil, nil)
	})
	register(cur, picky, "v78", func(s core.Store) core.Logic { return pickyLogic{Logic: implv0.New(s)} })

	println("active:", core.ImplVersion())
	drift := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), drifting))
	execute(cur, drift)
	println("v77 under v0:", decided(drift), "| active:", core.ImplVersion())
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v1")))
	println("then v1:", core.ImplVersion(), "| v77 would now build v1, retry:", revive(func() { ibcgov.Execute(cross(cur), drift) }), "| active:", core.ImplVersion())

	refused := govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), picky))
	execute(cur, refused)
	println("v78 over v1:", decided(refused), "| active:", core.ImplVersion())
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v0")))
	println("then v0:", core.ImplVersion(), "| v78 would now install, retry:", revive(func() { ibcgov.Execute(cross(cur), refused) }), "| active:", core.ImplVersion())
}

// Output:
// active: v0
// v77 under v0: spent - spent: implementation gno.land/r/aib/ibc/core/impl/v77 declared version v1 but builds version v0 | active: v0
// then v1: v1 | v77 would now build v1, retry: ibcgov: decision 1 is spent, not pending | active: v1
// v78 over v1: spent - spent: core impl v78 does not install over v1 | active: v1
// then v0: v0 | v78 would now install, retry: ibcgov: decision 3 is spent, not pending | active: v0
