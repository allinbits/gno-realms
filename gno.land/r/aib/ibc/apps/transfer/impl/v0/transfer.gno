package impl

import (
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
	"gno.land/r/nt/grc20reg/v0"
)

// Transfer classifies the denom, records in the proxy's store the send it
// authorizes for OnSendPacket, builds the packet and sends it through the IBC
// core. The proxy already checked that the caller is a direct user call, so
// unsafe.OriginSend describes coins that landed at the proxy and
// unsafe.OriginCaller is the packet sender. The proxy clears the recorded
// send on every exit path.
func (l *logic) Transfer(_ int, rlm realm, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	sender := unsafe.OriginCaller().String()
	switch {
	case strings.HasPrefix(denom, "ibc/"):
		// IBC voucher: the voucher GRC20 token is burnt in OnSendPacket.
		// Native coins sent with a voucher transfer would be stuck at the
		// proxy.
		if len(unsafe.OriginSend()) > 0 {
			panic("voucher transfer must not include native coins")
		}
		// Validate it exists and resolve the denom path.
		if l.store.VoucherToken(denom) == nil {
			panic(ufmt.Errorf("voucher token not found for denom %s", denom))
		}
		d, found := l.store.Denom(denom)
		if !found {
			panic(ufmt.Sprintf("denom %s not found in store", denom))
		}
		l.store.SetPendingVoucherSend(0, rlm, sender, clientID, d.Path(), amount)
		denom = d.Path()
	case grc20reg.Get(denom) != nil:
		// Non-IBC GRC20 token: escrow via TransferFrom happens in
		// OnSendPacket. Native coins sent with a GRC20 transfer would be
		// stuck at the proxy.
		if len(unsafe.OriginSend()) > 0 {
			panic("GRC20 transfer must not include native coins")
		}
		// Replace the denom with a slash-free alias for the IBC packet.
		// This avoids ibc-go rejecting base denoms containing slashes.
		alias := transfer.GRC20Alias(denom)
		l.store.SetPendingGRC20Send(0, rlm, sender, clientID, alias, amount)
		denom = alias
	case strings.Contains(denom, "/"):
		// This case exists only for a better error message: a denom with
		// slashes that isn't in grc20reg is likely a mistyped GRC20 path.
		// Without it, the default (native coin) branch would give a
		// confusing "requires one non-zero coin to be sent" error.
		panic(ufmt.Sprintf("GRC20 token %s not found in grc20reg", denom))
	default:
		// Native coin: the coins landed at the proxy (direct user call,
		// checked by the proxy).
		sent := unsafe.OriginSend()
		if len(sent) != 1 || sent[0].Amount == 0 {
			panic("native transfer requires one non-zero coin to be sent")
		}
		if sent[0].Denom != denom || sent[0].Amount != amount {
			panic(ufmt.Sprintf(
				"sent coin %s does not match transfer args (denom=%s, amount=%d)",
				sent[0], denom, amount,
			))
		}
		// Hand the verified escrow off to OnSendPacket, which can no longer
		// read OriginSend safely (its previous realm is the core realm).
		l.store.SetPendingNativeEscrow(0, rlm, sent[0])
	}

	// The packet Sender is the EOA that signed the tx; OnSendPacket reads the
	// same value back to verify the packet Sender matches the signing EOA.
	data := ics20.NewFungibleTokenPacketData(
		denom,
		ufmt.Sprintf("%d", amount),
		sender,
		receiver,
		memo,
	)
	packet = types.MsgSendPacket{
		SourceClient: clientID,
		Payloads: []types.Payload{{
			SourcePort:      transfer.PortID,
			DestinationPort: transfer.PortID,
			Encoding:        transfer.EncodingProtobuf,
			Value:           data.ProtoMarshal(),
			Version:         transfer.V1,
		}},
		TimeoutTimestamp: timeoutTimestamp,
	}
	sequence = core.SendPacket(cross(rlm), packet)
	return
}
