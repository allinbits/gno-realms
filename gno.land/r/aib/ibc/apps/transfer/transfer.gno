package transfer

import (
	"chain"
	"chain/banker"
	"chain/runtime"
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
		if sent := cur.SentCoins(); len(sent) > 0 {
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
		// Native coin: verify SentCoins matches.
		sent := cur.SentCoins()
		if len(sent) != 1 || sent[0].Amount == 0 {
			panic("native transfer requires one non-zero coin to be sent")
		}
		if sent[0].Denom != denom || sent[0].Amount != amount {
			panic(ufmt.Sprintf(
				"sent coin %s does not match transfer args (denom=%s, amount=%d)",
				sent[0], denom, amount,
			))
		}
	}
	return transfer(clientID, receiver, denom, amount, timeoutTimestamp, memo)
}

// TransferVoucher transfers an IBC voucher token from the origin caller to the
// provided recipient. Unlike interacting with the underlying GRC20 directly,
// this helper works via MsgCall because the transfer realm can impersonate the
// origin caller against the voucher ledger it owns.
func TransferVoucher(cur realm, ibcDenom string, to address, amount int64) {
	if sent := cur.SentCoins(); len(sent) > 0 {
		panic("voucher transfer must not include native coins")
	}
	inst := getVoucher(ibcDenom)
	if inst == nil {
		panic(ufmt.Errorf("voucher token not found for denom %s", ibcDenom))
	}
	teller := inst.ledger.ImpersonateTeller(runtime.OriginCaller())
	if err := teller.Transfer(to, amount); err != nil {
		panic(ufmt.Errorf("transfer voucher %s error: %v", ibcDenom, err))
	}
}

// ApproveVoucher sets a spender allowance for an IBC voucher token on behalf
// of the origin caller. This exposes a MsgCall-friendly way to approve voucher
// transfers without interacting with grc20reg directly.
func ApproveVoucher(cur realm, ibcDenom string, spender address, amount int64) {
	if sent := cur.SentCoins(); len(sent) > 0 {
		panic("voucher approval must not include native coins")
	}
	inst := getVoucher(ibcDenom)
	if inst == nil {
		panic(ufmt.Errorf("voucher token not found for denom %s", ibcDenom))
	}
	teller := inst.ledger.ImpersonateTeller(runtime.OriginCaller())
	if err := teller.Approve(spender, amount); err != nil {
		panic(ufmt.Errorf("approve voucher %s error: %v", ibcDenom, err))
	}
}

func transfer(clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	data := NewFungibleTokenPacketData(
		denom,
		ufmt.Sprintf("%d", amount),
		runtime.OriginCaller().String(),
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
	sequence = core.SendPacket(cross, packet)
	return
}

func refundPacketToken(sourcePort, sourceClient, sender string, token Token) error {
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
		if err := unescrowGRC20(sender, coin); err != nil {
			return err
		}
	} else {
		// Native: return escrowed coins to sender
		if err := unescrowNative(sender, coin); err != nil {
			return err
		}
	}
	return nil
}

// unescrowGRC20 resolves the GRC20 alias and transfers the escrowed tokens
// back to the receiver via the token's RealmTeller.
func unescrowGRC20(receiver string, coin chain.Coin) error {
	denomKey := resolveGRC20Alias(coin.Denom)
	token := grc20reg.Get(denomKey)
	if token == nil {
		return ufmt.Errorf("GRC20 token %s not found in grc20reg", denomKey)
	}
	teller := token.RealmTeller()
	if err := teller.Transfer(address(receiver), coin.Amount); err != nil {
		return ufmt.Errorf("unescrow GRC20 %s error: %v", denomKey, err)
	}
	subEscrowForDenom(coin)
	return nil
}

// unescrowNative sends the escrowed native coins back to the receiver via
// the banker.
func unescrowNative(receiver string, coin chain.Coin) error {
	var (
		// TODO no app/clientID specific escrow address ?
		from   = runtime.CurrentRealm().Address()
		to     = address(receiver)
		amount = chain.NewCoins(coin)
		banker = banker.NewBanker(banker.BankerTypeRealmSend)
	)
	banker.SendCoins(from, to, amount)
	subEscrowForDenom(coin)
	return nil
}
