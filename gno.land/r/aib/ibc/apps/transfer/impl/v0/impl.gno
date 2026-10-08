// Package impl is the first implementation of the ICS-20 transfer logic,
// behind the gno.land/r/aib/ibc/apps/transfer proxy (see docs/adrs/0002). It
// holds no state of its own: it reads and writes the proxy's store and moves
// value through the proxy's Store services, emits through the proxy's Emit*
// wrappers and is always invoked non-crossing by the proxy, so the current
// realm is the proxy for the whole call and rlm is the proxy's live realm
// value. It exports nothing that mutates.
package impl

import (
	"gno.land/r/aib/ibc/apps/transfer"
)

const version = "v0"

type logic struct {
	store transfer.Store
}

var _ transfer.Logic = (*logic)(nil)

// New builds the implementation against the proxy's store. The proxy calls it
// through the constructor registered below.
func New(s transfer.Store) transfer.Logic {
	return &logic{store: s}
}

func init(cur realm) {
	transfer.RegisterImpl(cross(cur), New)
}

func (l *logic) Version() string {
	return version
}

// OnInstall has nothing to migrate: this is the first implementation and the
// store it expects is the store the proxy was deployed with.
func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {}
