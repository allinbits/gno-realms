// Package impl is the second implementation of the ICS-20 transfer logic,
// behind the gno.land/r/aib/ibc/apps/transfer proxy (see docs/adrs/0002 and
// docs/adrs/0004). It runs impl/v0's logic unchanged for every client that is
// not an Ethereum client, and puts every Ethereum client under the route
// controls of ADR pr6375 §7 (R8, R10, R12, R13, R17, R18, §7.13):
//
//   - an Ethereum client carries transfers only as the current client of a
//     route that ibcgov enrolled, and only for the denoms enabled on it; any
//     other Ethereum client refuses sends and error-acks receives;
//   - a send of a gno-native token checks the per-message minimum and
//     maximum, charges the route fee (paid to the route's fee collector),
//     refuses the zero, reserved and refused recipients and stops under a
//     sends flag; a voucher returning to Ethereum (a burn) is never limited,
//     charged or paused;
//   - every send writes an immutable send record (the full packet, its
//     commitment and the send's metadata) in the same transaction; the
//     acknowledgement and timeout callbacks attach the outcome, the local
//     processing height and the payment state;
//   - a refund (error acknowledgement or timeout) is paid under the route's
//     refund meter or queued, and only queued under a refunds hold; queued
//     refunds are paid by the permissionless ClaimRefunds;
//   - a receive is refused with an error acknowledgement before any state
//     change under a credits flag, for a denom not enabled on the route, or
//     past a minted denom's supply cap; otherwise it books a claim keyed by
//     the packet (or a sweep entry), in the transaction of the receipt, and
//     returns a success acknowledgement; claims are paid by the permissionless
//     Claim within the route's meters, nothing under a payouts flag;
//   - escrow, vouchers and controls are keyed by the route key; the denoms on
//     the wire carry the route's current client id, translated both ways, so a
//     route replacement re-points the route in constant work.
//
// The controls state lives in the proxy (Store.InitExt, gno.land/p/aib/ibc/
// ics20/controls/v0); the flags and holds live in gno.land/r/aib/ibc/ibcgov,
// which decides every governance operation (GovApply). Like v0, this realm
// holds no state, is always invoked non-crossing by the proxy, as the proxy,
// and exports nothing that mutates.
package impl

import (
	"chain/runtime"
	"time"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
)

const version = "v1"

// extKey is the proxy extension slot of the route controls.
const extKey = "controls"

type logic struct {
	transfer.Logic // impl/v0, for every client the controls do not cover
	store          transfer.Store
}

var (
	_ transfer.Logic         = (*logic)(nil)
	_ transfer.ControlsLogic = (*logic)(nil)
)

// New builds the implementation against the proxy's store.
func New(s transfer.Store) transfer.Logic {
	return &logic{Logic: implv0.New(s), store: s}
}

func init(cur realm) {
	transfer.RegisterImpl(cross(cur), New)
}

func (l *logic) Version() string { return version }

// OnInstall creates the route controls in the proxy, empty: every meter
// starts empty (ADR pr6375 §7.1). It installs over v0 or nothing, and
// re-installs over itself; anything else is refused.
func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	switch prevVersion {
	case "", "v0", version:
	default:
		panic(ufmt.Sprintf("transfer impl %s cannot install over version %s", version, prevVersion))
	}
	l.store.InitExt(0, rlm, extKey, controls.NewRegistryAny)
}

// registry is the controls state, mutable: only for the proxy's live rlm.
func (l *logic) registry(_ int, rlm realm) *controls.Registry {
	return l.store.Ext(0, rlm, extKey).(*controls.Registry)
}

// reader is the controls state, read only.
func (l *logic) reader() controls.Reader {
	rd, _ := l.store.ExtView(extKey).(controls.Reader)
	return rd
}

func now() int64 { return time.Now().Unix() }

func chainHeight() int64 { return runtime.ChainHeight() }
