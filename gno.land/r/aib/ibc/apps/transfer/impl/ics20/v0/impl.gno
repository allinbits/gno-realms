// Package impl is the plain ICS-20 transfer logic, behind the
// gno.land/r/aib/ibc/apps/transfer proxy (see docs/adrs/0002): sends,
// receives, acknowledgements and timeouts, escrow and vouchers, for any
// client. It registers nothing. The installed implementation,
// gno.land/r/aib/ibc/apps/transfer/impl/controls/v0, wraps it and puts every
// Ethereum client under the route controls (docs/adrs/0004); a chain without
// Ethereum, or the upgrade rehearsal, registers it through a wrapper realm of
// its own.
//
// This realm holds no state, is always invoked non-crossing by the proxy (or
// the realm wrapping it), as the proxy, and exports nothing that mutates.
package ics20

import (
	"gno.land/r/aib/ibc/apps/transfer"
)

const version = "v0"

// logic is the plain ICS-20 logic, built against the proxy's store.
type logic struct {
	store transfer.Store
}

var _ transfer.Logic = (*logic)(nil)

// New builds the plain ICS-20 implementation against the proxy's store. It
// registers nothing: the realm that wraps or registers it builds it here.
func New(s transfer.Store) transfer.Logic { return &logic{store: s} }

func (l *logic) Version() string {
	return version
}

func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {}
