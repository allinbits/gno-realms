package ics20

import (
	"chain"
	"math"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

// Token defines a struct which represents a token to be transferred.
type Token struct {
	// the token denomination
	Denom Denom
	// the token amount to be transferred, in decimal digits
	Amount string
}

// NewToken constructs a Token with the given native base denom and amount
// (no trace, no prefix hops). Provided so external callers — which cannot
// construct foreign-stamped composite literals under v2 borrow rule #1 —
// can still build Token values for tests and packet assembly.
func NewToken(baseDenom, amount string) Token {
	return Token{
		Denom:  NewDenom(baseDenom),
		Amount: amount,
	}
}

// AmountUint256 parses the Token.Amount field: decimal digits only (no sign,
// no space, no separator; leading zeros are read as strconv.ParseUint reads
// them), below 2^256, the range of an ICS20 amount on the wire.
func (t Token) AmountUint256() (uint256, error) {
	amt, err := strconv.ParseUint256(t.Amount, 10)
	if err != nil {
		return 0, ufmt.Errorf("unable to parse amount %q into uint256", t.Amount)
	}
	return amt, nil
}

// ToCoin converts a Token to a chain.Coin, whose amount is an int64: an
// amount above math.MaxInt64 is refused, since no coin can hold it.
func (t Token) ToCoin() (chain.Coin, error) {
	amt, err := t.AmountUint256()
	if err != nil {
		return chain.Coin{}, err
	}
	if amt > math.MaxInt64 {
		return chain.Coin{}, ufmt.Errorf("amount %s is above the chain's coin maximum", t.Amount)
	}
	return chain.NewCoin(t.Denom.IBCDenom(), int64(amt)), nil
}
