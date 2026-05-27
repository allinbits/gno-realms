package transfer_test

import (
	"chain"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/r/aib/ibc/apps/transfer"
)

func TestTokenToCoin(t *testing.T) {
	const (
		tokenDenom  = "atom/pool"
		tokenAmount = "100"
	)
	testCases := []struct {
		name     string
		token    transfer.Token
		expCoin  chain.Coin
		expError string
	}{
		{
			"success: convert token to coin",
			transfer.NewToken(tokenDenom, tokenAmount),
			chain.NewCoin(tokenDenom, 100),
			"",
		},
		{
			"failure: invalid amount string",
			transfer.NewToken(tokenDenom, "value"),
			chain.Coin{},
			"unable to parse amount \"value\" into int64",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {

			coin, err := tc.token.ToCoin()

			if tc.expError == "" {
				urequire.NoError(t, err, tc.name)
				return
			}
			urequire.ErrorContains(t, err, tc.expError)
			uassert.Equal(t, tc.expCoin.Amount, coin.Amount)
			uassert.Equal(t, tc.expCoin.Denom, coin.Denom)
		})
	}
}
