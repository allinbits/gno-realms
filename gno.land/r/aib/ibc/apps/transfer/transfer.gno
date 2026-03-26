package transfer

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"

	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
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
	// Validate that the GRC20 token exists and resolve the denom path.
	inst := getGRC20(denom)
	if inst == nil {
		panic(ufmt.Errorf("GRC20 token not found for denom %s", denom))
	}
	if strings.HasPrefix(denom, "ibc/") {
		// If denom is an ibc trace, replace it with the ibc path.
		d, found := getDenom(denom)
		if !found {
			panic(ufmt.Sprintf("denom %s not found in store", denom))
		}
		denom = d.Path()
	} else {
		// TODO GRC20 token is not IBC voucher, how do we transferFrom?
		panic("GRC20 non IBC voucher not handled")
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
		// Re-mint GRC20 tokens that were burnt during OnSendPacket
		inst := getGRC20(coin.Denom)
		if inst == nil {
			return ufmt.Errorf("GRC20 token not found for denom %s", coin.Denom)
		}
		if err := inst.ledger.Mint(address(sender), coin.Amount); err != nil {
			return ufmt.Errorf("re-mint GRC20 error: %v", err)
		}
	} else {
		if err := unescrowCoin(sender, coin); err != nil {
			return err
		}
	}
	return nil
}

// escrowCoins sends the specified amount of tokens from the realm to the
// original sender.
func unescrowCoin(sender string, coin chain.Coin) error {
	// Send back the amount from escrow address back to sender
	var (
		// TODO no app/clientID specific escrow address ?
		from   = runtime.CurrentRealm().Address()
		to     = address(sender)
		amount = chain.NewCoins(coin)
		banker = banker.NewBanker(banker.BankerTypeRealmSend)
	)
	banker.SendCoins(from, to, amount)

	subEscrowForDenom(coin)

	return nil
}
