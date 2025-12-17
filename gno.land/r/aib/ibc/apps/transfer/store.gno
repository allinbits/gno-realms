package transfer

import (
	"gno.land/p/nt/avl"
)

var (
	denoms *avl.Tree // ibcDenom:Denom
)

func init() {
	denoms = avl.NewTree()
}

func hasDenomMetadata(voucherDenom string) bool {
	return denoms.Has(voucherDenom)
}

func setDenomMetadata(denom Denom) {
	denoms.Set(denom.IBCDenom(), denom)
}
