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
	out.WriteString("## Dashboard\n\n")
	out.WriteString(ufmt.Sprintf("- Known IBC denoms: `%d`\n", denoms.Size()))
	out.WriteString(ufmt.Sprintf("- Escrow denoms: `%d`\n", totalEscrow.Size()))
	out.WriteString(ufmt.Sprintf("- Voucher GRC20 tokens: `%d`\n\n", voucherTokens.Size()))
	out.WriteString("## Endpoints\n\n")
	out.WriteString("- [`denoms`](/r/aib/ibc/apps/transfer:denoms): list known IBC denoms (`?page`, `?limit`)\n")
	out.WriteString("- `denoms/ibc/{hash}`: get metadata for an IBC denom\n")
	out.WriteString("- `total_escrow/{denom}`: get total escrow tracked for a base denom\n")
	out.WriteString("- `grc20/ibc/{hash}`: get GRC20 voucher token metadata\n")
	out.WriteString("- `grc20/ibc/{hash}/balance/{addr}`: get a GRC20 voucher balance for an address\n\n")
	out.WriteString("## Known denoms\n\n")
	if denoms.Size() == 0 {
		out.WriteString("No denom traces yet. Receive an IBC voucher, then refresh this page.\n")
	} else {
		denoms.IterateByOffset(0, denoms.Size(), func(_ string, v any) bool {
			d := v.(Denom)
			out.WriteString(ufmt.Sprintf(
				"- `%s`: [metadata](/r/aib/ibc/apps/transfer:denoms/%s) | [GRC20](/r/aib/ibc/apps/transfer:grc20/%s)\n",
				d.IBCDenom(), d.IBCDenom(), d.IBCDenom(),
			))
			out.WriteString(ufmt.Sprintf("  path: `%s`\n", d.Path()))
			return false
		})
	}
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
