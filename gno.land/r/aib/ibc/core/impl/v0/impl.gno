// Package impl is the first implementation of the IBC core lifecycle, behind
// the gno.land/r/aib/ibc/core proxy (see docs/adrs/0001). It holds no state of
// its own: it reads and writes the proxy's store through core.Store, emits
// through the proxy's Emit* wrappers and is always invoked non-crossing by the
// proxy's dispatchers, so the current realm is the proxy for the whole call
// and rlm is the proxy's live realm value. It exports nothing that mutates.
package impl

import (
	"gno.land/r/aib/ibc/core"
)

const version = "v0"

type logic struct {
	store core.Store
}

var _ core.Logic = (*logic)(nil)

// New builds the implementation against the proxy's store. The proxy calls it
// through the constructor registered below.
func New(s core.Store) core.Logic {
	return &logic{store: s}
}

func init(cur realm) {
	core.RegisterImpl(cross(cur), New)
}

func (l *logic) Version() string {
	return version
}

// OnInstall has nothing to migrate: this is the first implementation and the
// store it expects is the store the proxy was deployed with.
func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {}
