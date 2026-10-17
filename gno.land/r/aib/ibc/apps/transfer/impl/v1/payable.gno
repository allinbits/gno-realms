package impl

import (
	"chain"
	"chain/banker"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/nt/grc20reg/v0"
)

// payout is one payment a governed decision is about to make.
type payout struct {
	denom  string
	to     address
	amount int64
}

// payable is why making ps would fail, or "": every check payOut's token or
// banker call would fail on, made before anything changes, so a governed
// payout that cannot be made is refused (the decision spent) with every
// entitlement kept, never aborted halfway. Amounts are checked per denom in
// total: a recipient that is a valid address other than this realm; for a
// minted denom, its voucher token and the room left under the int64 supply;
// for a GRC20, its registered token, the route's escrow accounting and this
// realm's token balance; for a native coin, the escrow accounting and this
// realm's bank balance.
func (l *logic) payable(rt *controls.Route, ps []payout) string {
	self := chain.PackageAddress(transfer.PkgPath)
	totals := map[string]int64{}
	var order []string
	for _, p := range ps {
		if p.amount <= 0 {
			continue
		}
		if !p.to.IsValid() || p.to == self {
			return ufmt.Sprintf("cannot pay %s: not a valid recipient other than the transfer realm", string(p.to))
		}
		if _, ok := totals[p.denom]; !ok {
			order = append(order, p.denom)
		}
		if p.amount > maxInt64-totals[p.denom] {
			return "the payments of " + p.denom + " overflow"
		}
		totals[p.denom] += p.amount
	}
	for _, denom := range order {
		total := totals[denom]
		acc := rt.Denom(denom)
		if acc != nil && acc.Config.Kind == controls.KindMint {
			tok := l.store.VoucherToken(denom)
			if tok == nil {
				return "no voucher token for " + denom
			}
			if total > maxInt64-tok.TotalSupply() {
				return ufmt.Sprintf("minting %d %s would overflow its token supply", total, denom)
			}
			continue
		}
		if err := l.store.CheckEscrow(rt.Key, chain.NewCoin(denom, total)); err != nil {
			return err.Error()
		}
		if transfer.IsGRC20Alias(denom) {
			tok := grc20reg.Get(transfer.ResolveGRC20Alias(denom))
			if tok == nil {
				return "GRC20 token " + transfer.ResolveGRC20Alias(denom) + " not found in grc20reg"
			}
			if have := tok.BalanceOf(self); have < total {
				return ufmt.Sprintf("this realm holds %d of %s, short of %d", have, denom, total)
			}
			continue
		}
		if have := banker.NewReadonlyBanker().GetCoin(self, denom); have < total {
			return ufmt.Sprintf("this realm holds %d %s, short of %d", have, denom, total)
		}
	}
	return ""
}

const maxInt64 = int64(1<<63 - 1)
