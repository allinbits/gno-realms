// Package impl is the upgrade rehearsal implementation of the transfer app:
// v0's logic under another version, deployed, activated and rolled back by
// the e2e suite (e2e/upgrade_test.go). Kept outside gno.land/ like the core
// candidate; never deployed on a public chain, not listed in
// scripts/packages.sh.
package impl

import (
	"gno.land/r/aib/ibc/apps/transfer"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
)

type logic struct{ transfer.Logic }

func (logic) Version() string { return "v99" }

// New wraps v0's logic, built against the same store.
func New(s transfer.Store) transfer.Logic {
	return logic{Logic: implv0.New(s)}
}

func init(cur realm) {
	transfer.RegisterImpl(cross(cur), New)
}
