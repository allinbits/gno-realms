package transfer

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"

	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt"
	"gno.land/r/aib/ibc/core"
)

// Transfer is a shortcut function for sending a token to an other chain using
// the IBC protocol. The token must be sent by the caller using the send field
// of the transaction.
func Transfer(cur realm, clientID, receiver string, timeoutTimestamp int64) (
	packet types.MsgSendPacket, sequence uint64,
) {
	sent := cur.Coins()
	if len(sent) != 1 || sent[0].Amount == 0 {
		panic("Transfer requires one non-zero coin to be sent")
	}
	denom := sent[0].Denom
	if strings.HasPrefix(denom, "ibc/") {
		d, found := getDenom(denom)
		if !found {
			panic(ufmt.Sprintf("denom %s not found in store", denom))
		}
		denom = d.Path()
	}
	data := FungibleTokenPacketData{
		Denom:    denom,
		Amount:   ufmt.Sprintf("%d", sent[0].Amount),
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
		TimeoutTimestamp: uint64(timeoutTimestamp),
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
		to := runtime.OriginCaller()
		if err := inst.ledger.Mint(to, coin.Amount); err != nil {
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
