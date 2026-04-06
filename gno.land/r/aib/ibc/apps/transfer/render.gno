package transfer

import (
	"chain"
	"chain/runtime"
	"strings"

	"gno.land/p/aib/jsonpage"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/json"
)

func Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("denoms", renderDenoms)
	router.HandleFunc("denoms/ibc/{hash}", renderDenom)
	router.HandleFunc("total_escrow/{denom}", renderTotalEscrowForDenom)
	router.HandleFunc("vouchers", renderVouchers)
	router.HandleFunc("voucher/ibc/{hash}", renderVoucher)
	router.HandleFunc("voucher/ibc/{hash}/balance/{addr}", renderVoucherBalance)
	return router.Render(path)
}

func renderHome(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	out.WriteString("# IBC transfer\n\n")
	out.WriteString("ICS-20 style transfer state and voucher token queries.\n\n")
	out.WriteString(ufmt.Sprintf("## Vouchers (%d)\n\n", denoms.Size()))
	if denoms.Size() > 0 {
		out.WriteString("| Denom | Base | Path | Supply | GRC20 |\n")
		out.WriteString("|-------|------|------|--------|-------|\n")
		denoms.IterateByOffset(0, denoms.Size(), func(_ string, v any) bool {
			d := v.(Denom)
			ibcDenom := d.IBCDenom()
			supply := ""
			grc20link := ""
			if inst := getVoucher(ibcDenom); inst != nil {
				supply = ufmt.Sprintf("[%d](/r/aib/ibc/apps/transfer:voucher/%s)", inst.token.TotalSupply(), ibcDenom)
				key := grc20regKey(ibcDenom)
				// Shorten the hash suffix: "gno.land/r/.../transfer.CAEF9C..." → keep prefix + first 4 … last 4 of hash
				dotIdx := strings.LastIndex(key, ".")
				shortKey := key
				if dotIdx != -1 {
					hash := key[dotIdx+1:]
					if len(hash) > 10 {
						shortKey = key[:dotIdx+1] + hash[:4] + "…" + hash[len(hash)-4:]
					}
				}
				const grc20regPath = "gno.land/r/demo/defi/grc20reg"
				grc20link = ufmt.Sprintf("[%s](%s:%s)", shortKey, stripDomain(grc20regPath), key)
			}
			out.WriteString(ufmt.Sprintf(
				"| [`%s`](/r/aib/ibc/apps/transfer:denoms/%s) | %s | %s | %s | %s |\n",
				shortDenom(ibcDenom), ibcDenom, d.Base, d.Path(), supply, grc20link,
			))
			return false
		})
		out.WriteString("\n")
	} else {
		out.WriteString("No vouchers yet.\n\n")
	}
	out.WriteString(ufmt.Sprintf("## Escrow (%d)\n\n", totalEscrow.Size()))
	if totalEscrow.Size() > 0 {
		out.WriteString("| Denom | Amount |\n")
		out.WriteString("|-------|--------|\n")
		totalEscrow.IterateByOffset(0, totalEscrow.Size(), func(_ string, v any) bool {
			c := v.(chain.Coin)
			out.WriteString(ufmt.Sprintf(
				"| [`%s`](/r/aib/ibc/apps/transfer:total_escrow/%s) | %d |\n",
				c.Denom, c.Denom, c.Amount,
			))
			return false
		})
		out.WriteString("\n")
	} else {
		out.WriteString("No escrow yet.\n\n")
	}
	out.WriteString("## JSON endpoints\n\n")
	out.WriteString("- [`denoms`](/r/aib/ibc/apps/transfer:denoms): list known IBC denoms (`?page`, `?limit`)\n")
	out.WriteString("- `denoms/ibc/{hash}`: get metadata for an IBC denom\n")
	out.WriteString("- `total_escrow/{denom}`: get total escrow tracked for a base denom\n")
	out.WriteString("- [`vouchers`](/r/aib/ibc/apps/transfer:vouchers): list voucher tokens (`?page`, `?limit`)\n")
	out.WriteString("- `voucher/ibc/{hash}`: get voucher token metadata\n")
	out.WriteString("- `voucher/ibc/{hash}/balance/{addr}`: get a voucher balance for an address\n\n")
	w.Write(out.String())
}

func renderDenoms(w *mux.ResponseWriter, r *mux.Request) {
	renderNode(w, jsonpage.Render(denoms, r, nil))
}

func renderDenom(w *mux.ResponseWriter, r *mux.Request) {
	denom := "ibc/" + r.GetVar("hash")
	d, ok := denoms.Get(denom)
	if !ok {
		renderNode(w, nodeError(ufmt.Sprintf("denom %s not found", denom)))
		return
	}
	renderNode(w, d.(Denom).RenderJSON())
}

func renderTotalEscrowForDenom(w *mux.ResponseWriter, r *mux.Request) {
	denom := r.GetVar("denom")
	var amt int64
	x, found := totalEscrow.Get(denom)
	if found {
		amt = x.(chain.Coin).Amount
	}
	renderNode(w, json.ObjectNode("", map[string]*json.Node{
		"denom":  json.StringNode("", denom),
		"amount": json.NumberNode("", float64(amt)),
	}))
}

func renderVouchers(w *mux.ResponseWriter, r *mux.Request) {
	renderNode(w, jsonpage.Render(voucherTokens, r, func(key string, v any) *json.Node {
		inst := v.(*voucher)
		return json.ObjectNode("", map[string]*json.Node{
			"denom":        json.StringNode("", key),
			"grc20reg_key": json.StringNode("", grc20regKey(key)),
			"name":         json.StringNode("", inst.token.GetName()),
			"symbol":       json.StringNode("", inst.token.GetSymbol()),
			"decimals":     json.NumberNode("", float64(inst.token.GetDecimals())),
			"total_supply": json.NumberNode("", float64(inst.token.TotalSupply())),
		})
	}))
}

func renderVoucher(w *mux.ResponseWriter, r *mux.Request) {
	ibcDenom := "ibc/" + r.GetVar("hash")
	inst := getVoucher(ibcDenom)
	if inst == nil {
		renderNode(w, nodeError("voucher token %s not found", ibcDenom))
		return
	}
	renderNode(w, json.ObjectNode("", map[string]*json.Node{
		"denom":        json.StringNode("", ibcDenom),
		"grc20reg_key": json.StringNode("", grc20regKey(ibcDenom)),
		"name":         json.StringNode("", inst.token.GetName()),
		"symbol":       json.StringNode("", inst.token.GetSymbol()),
		"decimals":     json.NumberNode("", float64(inst.token.GetDecimals())),
		"total_supply": json.NumberNode("", float64(inst.token.TotalSupply())),
	}))
}

func renderVoucherBalance(w *mux.ResponseWriter, r *mux.Request) {
	ibcDenom := "ibc/" + r.GetVar("hash")
	addr := r.GetVar("addr")
	inst := getVoucher(ibcDenom)
	if inst == nil {
		renderNode(w, nodeError("voucher token %s not found", ibcDenom))
		return
	}
	balance := inst.token.BalanceOf(address(addr))
	renderNode(w, json.ObjectNode("", map[string]*json.Node{
		"denom":   json.StringNode("", ibcDenom),
		"address": json.StringNode("", addr),
		"balance": json.NumberNode("", float64(balance)),
	}))
}

// stripDomain removes the domain from a gno pkg path for use in URLs.
// "gno.land/r/demo/foo" → "/r/demo/foo"
func stripDomain(path string) string {
	i := strings.Index(path, "/")
	if i != -1 {
		return path[i:]
	}
	return path
}

// shortDenom shortens an IBC denom hash for display.
// "ibc/CAEF9CABC…9D0F" (ibc/ + first 4 + … + last 4)
func shortDenom(ibcDenom string) string {
	const prefix = "ibc/"
	if !strings.HasPrefix(ibcDenom, prefix) {
		return ibcDenom
	}
	hash := ibcDenom[len(prefix):]
	if len(hash) > 10 {
		return prefix + hash[:4] + "…" + hash[len(hash)-4:]
	}
	return ibcDenom
}

func renderNode(w *mux.ResponseWriter, n *json.Node) {
	bz, err := json.Marshal(n)
	if err != nil {
		panic(err)
	}
	w.Write(string(bz))
}

// grc20regKey returns the grc20reg key for a voucher ibc denom.
// e.g. "ibc/CAEF9C..." → "gno.land/r/aib/ibc/apps/transfer.CAEF9C..."
func grc20regKey(ibcDenom string) string {
	return runtime.CurrentRealm().PkgPath() + "." + ibcDenom[len("ibc/"):]
}

func nodeError(msg string, args ...any) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"error": json.StringNode("", ufmt.Sprintf(msg, args...)),
	})
}
