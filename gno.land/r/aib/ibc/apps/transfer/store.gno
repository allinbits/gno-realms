package transfer

import (
	"chain"

	"gno.land/p/nt/avl"
)

var (
	denoms      *avl.Tree // ibcDenom:Denom
	totalEscrow *avl.Tree // denom:chain.Coin
)

func init() {
	denoms = avl.NewTree()
	totalEscrow = avl.NewTree()
}

func hasDenom(voucherDenom string) bool {
	return denoms.Has(voucherDenom)
}

func setDenom(denom Denom) {
	denoms.Set(denom.IBCDenom(), denom)
}

func getDenom(ibcDenom string) (Denom, bool) {
	x, found := denoms.Get(ibcDenom)
	if !found {
		return Denom{}, false
	}
	return x.(Denom), true
}

func addEscrowForDenom(c chain.Coin) {
	x, found := totalEscrow.Get(c.Denom)
	if found {
		c = x.(chain.Coin).Add(c)
	}
	totalEscrow.Set(c.Denom, c)
}

func subEscrowForDenom(c chain.Coin) {
	x, found := totalEscrow.Get(c.Denom)
	if !found {
		x = chain.Coin{Denom: c.Denom}
	}
	c = x.(chain.Coin).Sub(c)
	totalEscrow.Set(c.Denom, c)
}
