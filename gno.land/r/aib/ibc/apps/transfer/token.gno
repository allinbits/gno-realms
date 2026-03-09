package transfer

import (
	"chain"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

// Token defines a struct which represents a token to be transferred.
type Token struct {
	// the token denomination
	Denom Denom
	// the token amount to be transferred
	Amount string
}

// ToCoin converts a Token to an chain.Coin.
//
// The function parses the Token.Amount field and returns a new sdk.Coin with
// the IBCDenom of the Token's Denom field and the parsed Amount.
// If the Amount cannot be parsed, an error is returned with a wrapped error
// message.
func (t Token) ToCoin() (chain.Coin, error) {
	amt, err := t.AmountInt64()
	if err != nil {
		return chain.Coin{}, err
	}
	return chain.NewCoin(t.Denom.IBCDenom(), amt), nil
}

func (t Token) AmountInt64() (int64, error) {
	amt, err := strconv.ParseInt(t.Amount, 10, 64)
	if err != nil {
		return 0, ufmt.Errorf("unable to parse amount %q into int64", t.Amount)
	}
	return amt, nil
}
