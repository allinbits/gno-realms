// Package impl is the upgrade rehearsal implementation of the IBC core: v0's
// logic under another version. The e2e suite deploys it onto the running
// chain with addpkg, switches to it through GovDAO, relays packets, and rolls
// back to v0 (e2e/upgrade_test.go). It lives outside gno.land/ on purpose:
// gnodev eagerly loads every package of its workspace on reload, which would
// make the deployment step impossible to rehearse. Never deployed on a public
// chain, not listed in scripts/packages.sh.
package impl

import (
	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
)

type logic struct{ core.Logic }

func (logic) Version() string { return "v99" }

// New wraps v0's logic, built against the same store.
func New(s core.Store) core.Logic {
	return logic{Logic: implv0.New(s)}
}

func init(cur realm) {
	core.RegisterImpl(cross(cur), New)
}
