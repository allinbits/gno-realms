// PKGPATH: gno.land/r/demo/foreignapp
package foreignapp

import (
	"testing"
	"time"

	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const self = "gno.land/r/demo/foreignapp"

func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm(self))
	return ibcgov.LastDecision()
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// An administrative decision whose call fails on the live state when it is
// executed is spent, deterministically (ADR pr6375 §5.4, §6.6; Codex review
// #15): it never stays pending, to run later under its old approval once the
// state changes back.
func main(cur realm) {
	app := appstesting.NewApp(cross(cur))
	core.RegisterApp(cross(cur), "appx", app)
	println("pending:", core.IsAppPending("appx", self))

	approve := govern(cur, ibcgov.NewCoreApproveAppRequest(cross(cur), "appx", self))
	reject := govern(cur, ibcgov.NewCoreRejectAppRequest(cross(cur), "appx", self))
	println("reject:", decided(reject), "| pending:", core.IsAppPending("appx", self))

	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), approve)
	println("approve executed:", decided(approve))

	// The registration comes back: the old approval never applies to it.
	core.RegisterApp(cross(cur), "appx", app)
	println("retry:", revive(func() { ibcgov.Execute(cross(cur), approve) }))
	println("registered:", core.AppPkgPath("appx") != "", "| pending again:", core.IsAppPending("appx", self))
}

// Output:
// pending: true
// reject: applied - core reject app | pending: false
// approve executed: spent - spent: no pending registration of gno.land/r/demo/foreignapp for port appx
// retry: ibcgov: decision 1 is spent, not pending
// registered: false | pending again: true
