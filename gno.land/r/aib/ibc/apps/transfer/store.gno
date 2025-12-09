package transfer

import (
	"strings"

	"gno.land/p/nt/avl"
	"gno.land/p/nt/ufmt"
)

type DenomMetadata struct {
	Base        string
	Display     string
	Symbol      string
	Description string
}

var denomsByBase *avl.Tree // base:DenomMetadata

func init() {
	denomsByBase = avl.NewTree()
}

func hasDenomMetadata(voucherDenom string) bool {
	return denomsByBase.Has(voucherDenom)
}

func setDenomMetadata(voucherDenom string, denom Denom) {
	dm := DenomMetadata{
		Base:        denom.IBCDenom(),
		Display:     denom.Path(),
		Symbol:      strings.ToUpper(denom.Base),
		Description: ufmt.Sprintf("IBC token from %s", denom.Path()),
	}
	denomsByBase.Set(voucherDenom, dm)
}
