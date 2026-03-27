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
// send field of the transaction.
func Transfer(cur realm, clientID, receiver string, timeoutTimestamp uint64) (
	packet types.MsgSendPacket, sequence uint64,
) {
	sent := cur.SentCoins()
	if len(sent) != 1 || sent[0].Amount == 0 {
		panic("Transfer requires one non-zero coin to be sent")
	}
	return transfer(clientID, receiver, sent[0].Denom, sent[0].Amount, timeoutTimestamp)
}

// TransferGRC20 can be used to send a GRC20 token to another chain using the
// IBC protocol.
// That token can be an IBC voucher (minted when received a token from another
// chain), or any other GRC20 token.
func TransferGRC20(cur realm, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64) (
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
		// Non-IBC GRC20 token: escrow via TransferFrom.
		// The caller must have approved the transfer app realm address
		// for the given amount before calling this function.
		token := grc20reg.Get(denom)
		if token == nil {
			panic(ufmt.Sprintf("GRC20 token %s not found in grc20reg", denom))
		}
		sender := runtime.OriginCaller()
		escrowAddr := runtime.CurrentRealm().Address()
		teller := token.RealmTeller()
		if err := teller.TransferFrom(sender, escrowAddr, amount); err != nil {
			panic(ufmt.Errorf("TransferFrom GRC20 error: %v", err))
		}
		// Replace the denom with a slash-free alias for the IBC packet.
		// This avoids ibc-go rejecting base denoms containing slashes.
		denom = GRC20Alias(denom)
	}
	return transfer(clientID, receiver, denom, amount, timeoutTimestamp)
}

func transfer(clientID, receiver, denom string, amount int64, timeoutTimestamp uint64) (
	packet types.MsgSendPacket, sequence uint64,
) {
	data := FungibleTokenPacketData{
		Denom:    denom,
		Amount:   ufmt.Sprintf("%d", amount),
		Sender:   runtime.OriginCaller().String(),
		Receiver: receiver,
	}
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
	} else {
		if err := unescrow(sender, coin); err != nil {
			return err
		}
	}
	return nil
}

// unescrow sends the specified amount of tokens from the realm escrow back to
// the original sender. It handles both native coins (via banker) and non-IBC
// GRC20 tokens (via RealmTeller).
func unescrow(receiver string, coin chain.Coin) error {
	if isGRC20Alias(coin.Denom) {
		// Non-IBC GRC20 token: resolve alias to grc20reg key and transfer
		// from escrow back to receiver.
		denomKey := resolveGRC20Alias(coin.Denom)
		token := grc20reg.Get(denomKey)
		if token == nil {
			return ufmt.Errorf("GRC20 token %s not found in grc20reg", denomKey)
		}
		teller := token.RealmTeller()
		if err := teller.Transfer(address(receiver), coin.Amount); err != nil {
			return ufmt.Errorf("unescrow GRC20 %s error: %v", denomKey, err)
		}
	} else {
		// Native coin: send from realm escrow via banker
		var (
			// TODO no app/clientID specific escrow address ?
			from   = runtime.CurrentRealm().Address()
			to     = address(receiver)
			amount = chain.NewCoins(coin)
			banker = banker.NewBanker(banker.BankerTypeRealmSend)
		)
		banker.SendCoins(from, to, amount)
	}

	subEscrowForDenom(coin)

	return nil
}
