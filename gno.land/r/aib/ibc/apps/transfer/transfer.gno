package transfer

import (
	"chain"
	"chain/banker"
	"chain/runtime"

	"gno.land/p/nt/ufmt"
)

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
		// TODO track in store ?
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
	// Send the amount from sender to realm address
	var (
		from = runtime.OriginCaller()
		// TODO no app/clientID specific escrow address ?
		to     = runtime.CurrentRealm().Address()
		amount = chain.NewCoins(coin)
	)
	banker.SendCoins(from, to, amount)

	// TODO track escrowed coins by denom/client in store?

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

	// TODO track escrowed coins by denom/client in store?

	return nil
}
