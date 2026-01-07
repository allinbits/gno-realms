package transfer

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"time"

	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt"
	"gno.land/r/aib/ibc/core"
)

// Transfer is a shortcut function for sending a token to an other chain using
// the IBC protocol. The token must be sent by the caller using the send field
// of the transaction.
func Transfer(cur realm, clientID, receiver string) {
	runtime.AssertOriginCall()

	sent := banker.OriginSend()
	if len(sent) != 1 {
		panic("Transfer requires one coin to be sent")
	}
	if sent[0].IsZero() {
		panic("Transfer requires one non-zero coin")
	}
	var (
		amount = ufmt.Sprintf("%d", sent[0].Amount)
		denom  = sent[0].Denom
	)
	if strings.HasPrefix(denom, "ibc/") {
		d, found := getDenom(denom)
		if !found {
			panic(ufmt.Sprintf("denom %s not found in store", denom))
		}
		denom = d.Path()
	}
	var (
		sender  = runtime.OriginCaller()
		payload = FungibleTokenPacketData{
			Denom:    denom,
			Amount:   amount,
			Sender:   sender.String(),
			Receiver: receiver,
		}
		packet = types.MsgSendPacket{
			SourceClient:     clientID,
			TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
			Payloads: []types.Payload{
				{
					SourcePort:      PortID,
					DestinationPort: PortID,
					Encoding:        EncodingProtobuf,
					Value:           payload.ProtoMarshal(),
					Version:         V1,
				},
			},
		}
	)

	core.SendPacket(cross, nil, packet)
}

func refundPacketToken(sourcePort, sourceClient, sender string, token Token) error {
	coin, err := token.ToCoin()
	if err != nil {
		return ufmt.Errorf("token to coin error: %v", err)
	}
	if token.Denom.HasPrefix(sourcePort, sourceClient) {
		// Mint coin that was burnt during OnSendPacket and send it back to
		// sender
		var (
			from   = runtime.CurrentRealm().Address()
			to     = runtime.OriginCaller()
			amount = chain.NewCoins(coin)
		)
		banker := banker.NewBanker(banker.BankerTypeRealmIssue)
		banker.IssueCoin(from, coin.Denom, coin.Amount)
		banker.SendCoins(from, to, amount)
	} else {
		if err := unescrowCoin(sender, coin); err != nil {
			return err
		}
	}
	return nil
}

// escrowCoins sends the specified amount of tokens from the sender to the
// realm address.
func escrowCoin(banker banker.Banker, coin chain.Coin) error {
	if banker != nil { // FIXME remove banker from params
		// Send the amount from sender to realm address
		var (
			from = runtime.OriginCaller()
			// TODO no app/clientID specific escrow address ?
			to     = runtime.CurrentRealm().Address()
			amount = chain.NewCoins(coin)
		)
		banker.SendCoins(from, to, amount)
	}

	addEscrowForDenom(coin)

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
