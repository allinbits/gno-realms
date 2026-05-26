package transfer

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/aib/jsonpage"
	"gno.land/p/moul/txlink"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/json"
	"gno.land/r/aib/ibc/core"
)

// transferRealmPath is the package path of this realm; used to compute
// per-voucher GRC20 registry keys. Hardcoded because we cannot read it from
// runtime.CurrentRealm() in v2 without the unsafe package, and Render needs
// it from a non-crossing render handler.
const transferRealmPath = "gno.land/r/aib/ibc/apps/transfer"

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
	out.WriteString(renderTransferLinks())
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

// renderTransferLinks returns the "## Transfer" section: a set of txlinks
// that wallets can turn into MsgCalls to Transfer. Each link leaves at least
// one argument empty so the user fills it in their wallet.
func renderTransferLinks() string {
	var out strings.Builder
	out.WriteString("## Transfer\n\n")

	clientIDs := core.ClientIDs()
	if len(clientIDs) == 0 {
		out.WriteString("No IBC client registered yet — create one in [`/r/aib/ibc/core`](/r/aib/ibc/core) before transferring.\n\n")
		return out.String()
	}

	out.WriteString("Trigger an IBC transfer from your wallet. Pick the client of the destination chain:\n\n")
	for _, clientID := range clientIDs {
		out.WriteString(ufmt.Sprintf(
			"- [send via `%s`](%s) ([client details](/r/aib/ibc/core:clients/%s))\n",
			clientID, newTransferLink(clientID, "", "").URL(), clientID,
		))
	}

	// Per-voucher links: send back via IBC, plus local GRC20 send/approve.
	// All pre-fill the voucher denom; the user only fills the counterparty
	// and amount (and timeout for the IBC send) in their wallet.
	if denoms.Size() > 0 {
		out.WriteString("\n### Per-voucher actions\n\n")
		denoms.IterateByOffset(0, denoms.Size(), func(_ string, v any) bool {
			d := v.(Denom)
			if d.IsNative() {
				return false
			}
			sourceClient := d.Trace[0].ClientId
			ibcDenom := d.IBCDenom()
			out.WriteString(ufmt.Sprintf(
				"- `%s` (%s): [send back](%s) via `%s` — [send](%s) — [approve](%s)\n",
				shortDenom(ibcDenom), d.Base,
				newTransferLink(sourceClient, "", ibcDenom).URL(),
				sourceClient,
				newVoucherSendLink(ibcDenom).URL(),
				newVoucherApproveLink(ibcDenom).URL(),
			))
			return false
		})
	}
	out.WriteString("\n")
	return out.String()
}

// newVoucherSendLink builds a txlink to VoucherSend with the ibc denom
// pre-filled. The user fills `to` and `amount` in their wallet.
func newVoucherSendLink(ibcDenom string) *txlink.TxBuilder {
	return txlink.NewLink("VoucherSend").AddArgs(
		"ibcDenom", ibcDenom,
		"to", "",
		"amount", "",
	)
}

// newVoucherApproveLink builds a txlink to VoucherApprove with the ibc denom
// pre-filled. The user fills `spender` and `amount` in their wallet.
func newVoucherApproveLink(ibcDenom string) *txlink.TxBuilder {
	return txlink.NewLink("VoucherApprove").AddArgs(
		"ibcDenom", ibcDenom,
		"spender", "",
		"amount", "",
	)
}

// newTransferLink builds a txlink to the Transfer function with the given
// pre-filled arguments. Empty values are left wallet-settable.
// timeoutTimestamp defaults to one hour from now (in unix seconds), matching
// what the e2e tests use; the user can still override it in their wallet.
func newTransferLink(clientID, receiver, denom string) *txlink.TxBuilder {
	timeoutTimestamp := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	return txlink.NewLink("Transfer").AddArgs(
		"clientID", clientID,
		"receiver", receiver,
		"denom", denom,
		"amount", "",
		"timeoutTimestamp", timeoutTimestamp,
		"memo", "",
	)
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
	return transferRealmPath + "." + ibcDenom[len("ibc/"):]
}

func nodeError(msg string, args ...any) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"error": json.StringNode("", ufmt.Sprintf(msg, args...)),
	})
}
