// Package impl is the first implementation of the ICS-20 transfer logic,
// behind the gno.land/r/aib/ibc/apps/transfer proxy (see docs/adrs/0002 and
// docs/adrs/0004). It runs the plain ICS-20 logic (base) for every client that
// is not an Ethereum client, and puts every Ethereum client under the route
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
// which decides every governance operation (GovApply). This realm
// holds no state, is always invoked non-crossing by the proxy, as the proxy,
// and exports nothing that mutates.
package impl

import (
	"gno.land/r/aib/ibc/apps/transfer"
)

const version = "v0"

// base is the ICS-20 logic of every client the route controls do not cover
// (any client but an Ethereum one), which logic embeds.
type base struct {
	store transfer.Store
}

var _ transfer.Logic = (*base)(nil)

func (l *base) Version() string {
	return version
}

func (l *base) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {}
