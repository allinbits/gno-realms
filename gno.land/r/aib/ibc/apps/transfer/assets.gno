package transfer

import "chain"

// ClientAssets lists the denoms of the transfer state clientID holds: the
// vouchers in circulation that came over it (its first trace hop, by IBC
// denom) and what it escrowed (by escrow denom), in store order. The staged
// activation of the route controls must stage every Ethereum client with
// any, and every one of these denoms; a client with any cannot become
// another route's client (ADR pr6375 R17, R18). It walks every voucher, so
// its work grows with the number of voucher denoms.
func ClientAssets(clientID string) []string {
	var out []string
	if t := getEscrowForClient(clientID); t != nil {
		t.Iterate("", "", func(_ string, v any) bool {
			if c := v.(chain.Coin); c.Amount > 0 {
				out = append(out, c.Denom)
			}
			return false
		})
	}
	voucherTokens.Iterate("", "", func(ibcDenom string, v any) bool {
		d, ok := getDenom(ibcDenom)
		if ok && d.HasPrefix(PortID, clientID) && v.(*voucher).token.TotalSupply() > 0 {
			out = append(out, ibcDenom)
		}
		return false
	})
	return out
}
