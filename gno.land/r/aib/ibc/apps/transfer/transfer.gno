package transfer

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
	"gno.land/r/demo/defi/grc20reg"
)

// Transfer is the entry point for sending tokens to another chain using the
// IBC protocol. It supports three token types, detected automatically from the
// denom argument:
//   - IBC voucher (denom starts with "ibc/"): burns the voucher GRC20 token.
//   - Non-IBC GRC20 token (registered in grc20reg): escrows via TransferFrom.
//   - Native coin (everything else): the coin must be sent with the transaction
//     via the send field, and must match denom and amount.
//
// memo is included in the IBC packet payload.
func Transfer(cur realm, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	switch {
	case strings.HasPrefix(denom, "ibc/"):
		// IBC voucher: validate it exists and resolve the denom path.
		if getVoucher(denom) == nil {
			panic(ufmt.Errorf("voucher token not found for denom %s", denom))
		}
		d, found := getDenom(denom)
		if !found {
			panic(ufmt.Sprintf("denom %s not found in store", denom))
		}
		denom = d.Path()
	case grc20reg.Get(denom) != nil:
		// Non-IBC GRC20 token: convert to alias.
		// Escrow via TransferFrom happens in OnSendPacket.
		// Only catch the "stuck coins" mistake on direct user calls;
		// when a wrapper realm calls us, OriginSend describes the outer
		// tx envelope and the coins did not land at this realm.
		if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
			panic("GRC20 transfer must not include native coins")
		}
		// Replace the denom with a slash-free alias for the IBC packet.
		// This avoids ibc-go rejecting base denoms containing slashes.
		denom = GRC20Alias(denom)
	case strings.Contains(denom, "/"):
		// This case exists only for a better error message: a denom with
		// slashes that isn't in grc20reg is likely a mistyped GRC20 path.
		// Without it, the default (native coin) branch would give a
		// confusing "requires one non-zero coin to be sent" error.
		panic(ufmt.Sprintf("GRC20 token %s not found in grc20reg", denom))
	default:
		// Native coin: only direct user-call (maketx call) is accepted, so
		// unsafe.OriginSend() describes coins that actually landed at this
		// realm. Intermediate code realms or `maketx run` ephemeral realms
		// can attach -send to the tx but spend it elsewhere.
		if !cur.Previous().IsUserCall() {
			panic("native transfer must be a direct user call (maketx call)")
		}
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
		// safely read OriginSend (its PreviousRealm is the core realm).
		// The defer below guarantees we clear the slot in any exit path so
		// a leftover never bleeds into a later call.
		pendingNativeEscrow = &sent[0]
		defer func() { pendingNativeEscrow = nil }()
	}
	return transfer(cur, clientID, receiver, denom, amount, timeoutTimestamp, memo)
}

// VoucherSend is a convenience helper to send an IBC voucher token from the
// caller to the provided recipient.
func VoucherSend(cur realm, ibcDenom string, to address, amount int64) {
	inst := getVoucher(ibcDenom)
	if inst == nil {
		panic(ufmt.Errorf("voucher token not found for denom %s", ibcDenom))
	}
	teller := inst.ledger.ImpersonateTeller(cur.Previous().Address())
	if err := teller.Transfer(0, cur, to, amount); err != nil {
		panic(ufmt.Errorf("transfer voucher %s error: %v", ibcDenom, err))
	}
}

// VoucherApprove is a convenience helper to set a spender allowance for an IBC
// voucher token on behalf of the caller.
func VoucherApprove(cur realm, ibcDenom string, spender address, amount int64) {
	inst := getVoucher(ibcDenom)
	if inst == nil {
		panic(ufmt.Errorf("voucher token not found for denom %s", ibcDenom))
	}
	teller := inst.ledger.ImpersonateTeller(cur.Previous().Address())
	if err := teller.Approve(0, cur, spender, amount); err != nil {
		panic(ufmt.Errorf("approve voucher %s error: %v", ibcDenom, err))
	}
}

func transfer(cur realm, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	// unsafe.OriginCaller is the EOA that signed the tx; we use it as the
	// packet Sender so Transfer can also be invoked through a wrapper realm.
	// On the OnSendPacket side the same value is read back to verify the
	// packet Sender matches the signing EOA.
	data := NewFungibleTokenPacketData(
		denom,
		ufmt.Sprintf("%d", amount),
		unsafe.OriginCaller().String(),
		receiver,
		memo,
	)
	packet = types.MsgSendPacket{
		SourceClient: clientID,
		Payloads: []types.Payload{{
			SourcePort:      PortID,
			DestinationPort: PortID,
			Encoding:        EncodingProtobuf,
			Value:           data.ProtoMarshal(),
			Version:         V1,
		}},
		TimeoutTimestamp: timeoutTimestamp,
	}
	sequence = core.SendPacket(cross(cur), packet)
	return
}

// refundPacketToken is a non-crossing helper; rlm is the caller's live cur,
// needed only by unescrowNative which constructs a Banker.
func refundPacketToken(_ int, rlm realm, sourcePort, sourceClient, sender string, token Token) error {
	coin, err := token.ToCoin()
	if err != nil {
		return ufmt.Errorf("token to coin error: %v", err)
	}
	if token.Denom.HasPrefix(sourcePort, sourceClient) {
		// Re-mint voucher tokens that were burnt during OnSendPacket
		inst := getVoucher(coin.Denom)
		if inst == nil {
			return ufmt.Errorf("voucher token not found for denom %s", coin.Denom)
		}
		if err := inst.ledger.Mint(address(sender), coin.Amount); err != nil {
			return ufmt.Errorf("re-mint voucher error: %v", err)
		}
	} else if isGRC20Alias(coin.Denom) {
		// Non-IBC GRC20: return escrowed tokens to sender
		if err := unescrowGRC20(0, rlm, sender, coin); err != nil {
			return err
		}
	} else {
		// Native: return escrowed coins to sender
		if err := unescrowNative(0, rlm, sender, coin); err != nil {
			return err
		}
	}
	return nil
}

// unescrowGRC20 resolves the GRC20 alias and transfers the escrowed tokens
// back to the receiver via the token's RealmTeller. Non-crossing helper; rlm
// is needed by the grc20 teller API.
func unescrowGRC20(_ int, rlm realm, receiver string, coin chain.Coin) error {
	denomKey := resolveGRC20Alias(coin.Denom)
	token := grc20reg.Get(denomKey)
	if token == nil {
		return ufmt.Errorf("GRC20 token %s not found in grc20reg", denomKey)
	}
	teller := token.RealmTeller(0, rlm)
	if err := teller.Transfer(0, rlm, address(receiver), coin.Amount); err != nil {
		return ufmt.Errorf("unescrow GRC20 %s error: %v", denomKey, err)
	}
	subEscrowForDenom(coin)
	return nil
}

// unescrowNative sends the escrowed native coins back to the receiver via
// the banker. Non-crossing helper; rlm is the caller's live cur (transfer
// realm's own frame), needed to construct a Banker.
func unescrowNative(_ int, rlm realm, receiver string, coin chain.Coin) error {
	var (
		// TODO no app/clientID specific escrow address ?
		from   = rlm.Address()
		to     = address(receiver)
		amount = chain.NewCoins(coin)
		banker = banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	)
	banker.SendCoins(from, to, amount)
	subEscrowForDenom(coin)
	return nil
}

// pendingNativeEscrow is set by Transfer's native branch and read by
// OnSendPacket. It bridges the user-call boundary check (only doable from
// Transfer, where PreviousRealm() is the EOA) to the actual escrow update
// (done in OnSendPacket).
//
// Gno persists package-level vars to the realm store at end of tx, so this
// MUST be cleared before Transfer returns to avoid leaking into the next
// tx. Transfer uses a defer to guarantee the reset on every exit path.
var pendingNativeEscrow *chain.Coin
