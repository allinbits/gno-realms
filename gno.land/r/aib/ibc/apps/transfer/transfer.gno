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

// Transfer is an entry point function for sending a native token to another
// chain using the IBC protocol. The token must be sent by the caller using the
// send field of the transaction. memo is included in the IBC packet payload.
func Transfer(cur realm, clientID, receiver string, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	sent := cur.SentCoins()
	if len(sent) != 1 || sent[0].Amount == 0 {
		panic("Transfer requires one non-zero coin to be sent")
	}
	return transfer(clientID, receiver, sent[0].Denom, sent[0].Amount, timeoutTimestamp, memo)
}

// TransferGRC20 can be used to send a GRC20 token to another chain using the
// IBC protocol.
// That token can be an IBC voucher (minted when received a token from another
// chain), or any other GRC20 token. memo is included in the IBC packet
// payload.
func TransferGRC20(cur realm, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	if sent := cur.SentCoins(); len(sent) > 0 {
		panic("TransferGRC20 must not include native coins")
	}
	if strings.HasPrefix(denom, "ibc/") {
		// IBC voucher: validate it exists and resolve the denom path.
		if getVoucher(denom) == nil {
			panic(ufmt.Errorf("voucher token not found for denom %s", denom))
		}
		d, found := getDenom(denom)
		if !found {
			panic(ufmt.Sprintf("denom %s not found in store", denom))
		}
		denom = d.Path()
	} else {
		// Non-IBC GRC20 token: validate it exists and convert to alias.
		// Escrow via TransferFrom happens in OnSendPacket.
		if grc20reg.Get(denom) == nil {
			panic(ufmt.Sprintf("GRC20 token %s not found in grc20reg", denom))
		}
		// Replace the denom with a slash-free alias for the IBC packet.
		// This avoids ibc-go rejecting base denoms containing slashes.
		denom = GRC20Alias(denom)
	}
	return transfer(clientID, receiver, denom, amount, timeoutTimestamp, memo)
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
	denomKey, err := resolveGRC20Alias(coin.Denom)
	if err != nil {
		return ufmt.Errorf("resolve GRC20 alias %s error: %v", coin.Denom, err)
	}
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
