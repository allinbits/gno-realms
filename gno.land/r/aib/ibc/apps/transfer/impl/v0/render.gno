package impl

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/aib/jsonmd/v0"

	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/jsonpage/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/json/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// Render serves every path of the transfer realm: the proxy forwards its
// Render here (see transfer.Render). Escrow is tracked per (client, denom);
// the routes aggregate across all clients for display.
func (l *logic) Render(path string) string {
	router := mux.NewRouter()
	NewRenderer(l.store).Register(router)
	return router.Render(path)
}

// Renderer serves the routes of the transfer realm from a Store. It is
// exported, with its handlers and the helpers below, so a later implementation
// can reuse what it does not change:
//
//	rd := implv0.NewRenderer(store)
//	router.HandleFunc("", myHome) // overrides first: mux matches in registration order
//	rd.Register(router)
//
// A later implementation cannot build a Renderer literal (a realm cannot
// construct another realm's types), hence NewRenderer.
type Renderer struct {
	store transfer.Store
}

// NewRenderer returns a Renderer reading from s.
func NewRenderer(s transfer.Store) *Renderer {
	return &Renderer{store: s}
}

// Register installs every route of this implementation on router. Routes
// already registered on router take precedence.
func (rd *Renderer) Register(router *mux.Router) {
	router.HandleFunc("", rd.Home)
	router.HandleFunc("admin", rd.Admin)
	router.HandleFunc("denoms", rd.Denoms)
	router.HandleFunc("denoms/ibc/{hash}", rd.Denom)
	router.HandleFunc("total_escrow/{denom}", rd.TotalEscrowForDenom)
	router.HandleFunc("vouchers", rd.Vouchers)
	router.HandleFunc("voucher/ibc/{hash}", rd.Voucher)
	router.HandleFunc("voucher/ibc/{hash}/balance/{addr}", rd.VoucherBalance)
}

// homeListLimit caps every listing on the home page. Clients are never
// removed and, while the core's relayer whitelist is empty, anyone may create
// one, then mint vouchers or escrow through it: a listing of the whole set
// could be pushed past the query gas limit. Counts stay exact; the paginated
// JSON routes list everything.
const homeListLimit = 100

// HomeListLimit is homeListLimit, for implementations that rewrite the home
// page (impl/v1 rewrites the send-back links of the listed vouchers).
const HomeListLimit = homeListLimit

func (rd *Renderer) Home(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	out.WriteString("# IBC transfer\n\n")
	out.WriteString("ICS-20 style transfer state and voucher token queries.\n\n")
	if core.IsAppPaused(transfer.PortID) {
		out.WriteString("> **Paused** by the IBC core: transfers and incoming packets are refused; refunds still go through.\n\n")
	}
	out.WriteString(RenderImplDisclosure())
	out.WriteString(RenderTransferLinks())
	denoms := rd.store.Denoms()
	out.WriteString(ufmt.Sprintf("## Vouchers (%d)\n\n", denoms.Size()))
	if denoms.Size() > 0 {
		out.WriteString("| Denom | Base | Path | Supply | GRC20 | Actions |\n")
		out.WriteString("|-------|------|------|--------|-------|---------|\n")
		for _, d := range rd.DenomsByClientOrder(homeListLimit) {
			ibcDenom := d.IBCDenom()
			supply := ""
			grc20link := ""
			if token := rd.store.VoucherToken(ibcDenom); token != nil {
				supply = ufmt.Sprintf("[%d](/r/aib/ibc/apps/transfer:voucher/%s)", token.TotalSupply(), ibcDenom)
				key := GRC20RegKey(ibcDenom)
				// Shorten the hash suffix: "gno.land/r/.../transfer.CAEF9C..." → keep prefix + first 4 … last 4 of hash
				dotIdx := strings.LastIndex(key, ".")
				shortKey := key
				if dotIdx != -1 {
					hash := key[dotIdx+1:]
					if len(hash) > 10 {
						shortKey = key[:dotIdx+1] + hash[:4] + "…" + hash[len(hash)-4:]
					}
				}
				const grc20regPath = "gno.land/r/nt/grc20reg/v0"
				grc20link = ufmt.Sprintf("[%s](%s:%s)", shortKey, StripDomain(grc20regPath), key)
			}
			// Actions: IBC "send back" (via the voucher's source client) plus
			// local GRC20 send/approve. All pre-fill the voucher denom; the user
			// only fills the counterparty and amount (and timeout for the IBC
			// send) in their wallet.
			sourceClient := d.Trace[0].ClientId
			actions := ufmt.Sprintf(
				"[send back](%s) via `%s` — [send](%s) — [approve](%s)",
				NewTransferLink(sourceClient, "", ibcDenom).URL(),
				sourceClient,
				NewVoucherSendLink(ibcDenom).URL(),
				NewVoucherApproveLink(ibcDenom).URL(),
			)
			// The base denom comes from the counterparty's packet data and is
			// only checked for slashes on receive, so it can carry markdown:
			// escape it (and the path that embeds it) as a table cell.
			out.WriteString(ufmt.Sprintf(
				"| [`%s`](/r/aib/ibc/apps/transfer:denoms/%s) | %s | %s | %s | %s | %s |\n",
				ShortDenom(ibcDenom), ibcDenom, jsonmd.Cell(d.Base), jsonmd.Cell(d.Path()), supply, grc20link, actions,
			))
		}
		if denoms.Size() > homeListLimit {
			out.WriteString(ufmt.Sprintf("\nFirst %d of %d vouchers; see [`vouchers`](/r/aib/ibc/apps/transfer:vouchers) (`?page`, `?limit`) for all of them.\n", homeListLimit, denoms.Size()))
		}
		out.WriteString("\n")
	} else {
		out.WriteString("No vouchers yet.\n\n")
	}
	escrowTotals := rd.store.EscrowTotals()
	out.WriteString(ufmt.Sprintf("## Escrow (%d)\n\n", escrowTotals.Size()))
	if escrowTotals.Size() > 0 {
		out.WriteString("| Denom | Amount |\n")
		out.WriteString("|-------|--------|\n")
		escrowTotals.IterateByOffset(0, homeListLimit, func(denom string, v any) bool {
			out.WriteString(ufmt.Sprintf("| %s | %d |\n", escrowDenomCell(denom), v.(chain.Coin).Amount))
			return false
		})
		if escrowTotals.Size() > homeListLimit {
			out.WriteString(ufmt.Sprintf("\nFirst %d of %d escrowed denoms.\n", homeListLimit, escrowTotals.Size()))
		}
		out.WriteString("\n")
	} else {
		out.WriteString("No escrow yet.\n\n")
	}
	out.WriteString("## JSON endpoints\n\n")
	out.WriteString("- [`admin`](/r/aib/ibc/apps/transfer:admin): authority, pause state, blocked addresses\n")
	out.WriteString("- [`denoms`](/r/aib/ibc/apps/transfer:denoms): list known IBC denoms (`?page`, `?limit`)\n")
	out.WriteString("- `denoms/ibc/{hash}`: get metadata for an IBC denom\n")
	out.WriteString("- `total_escrow/{denom}`: get total escrow tracked for a base denom\n")
	out.WriteString("- [`vouchers`](/r/aib/ibc/apps/transfer:vouchers): list voucher tokens (`?page`, `?limit`)\n")
	out.WriteString("- `voucher/ibc/{hash}`: get voucher token metadata\n")
	out.WriteString("- `voucher/ibc/{hash}/balance/{addr}`: get a voucher balance for an address\n\n")
	w.Write(out.String())
}

// escrowDenomCell is an escrow table's denom cell: a link to its total when
// the denom is spelled in the bank's alphabet, else the denom escaped as
// table text (a GRC20 alias carries a token's chosen symbol).
func escrowDenomCell(denom string) string {
	for i := 0; i < len(denom); i++ {
		c := denom[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '/' || c == ':' || c == '.' || c == '_' || c == '-') {
			return jsonmd.Cell(denom)
		}
	}
	return "[`" + denom + "`](/r/aib/ibc/apps/transfer:total_escrow/" + denom + ")"
}

func (rd *Renderer) Admin(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	out.WriteString("## Authority\n\n")
	out.WriteString("- **Authority members**:\n")
	for _, m := range transfer.AuthorityMembers() {
		out.WriteString("  - " + string(m) + "\n")
	}
	out.WriteString(ufmt.Sprintf("- **Paused**: %t (set by the IBC core)\n", core.IsAppPaused(transfer.PortID)))
	out.WriteString(ufmt.Sprintf("- **Implementation**: %s\n", RenderImplRef(transfer.ImplPath(), transfer.ImplVersion())))
	out.WriteString("- **Registered implementations**:\n")
	for _, p := range transfer.RegisteredImplPaths() {
		out.WriteString("  - " + p + "\n")
	}
	blocked := transfer.BlockedAddresses()
	if len(blocked) == 0 {
		out.WriteString("- **Blocked addresses**: none\n")
	} else {
		out.WriteString("- **Blocked addresses**:\n")
		for _, b := range blocked {
			out.WriteString("  - " + string(b) + "\n")
		}
	}
	w.Write(out.String())
}

func (rd *Renderer) Denoms(w *mux.ResponseWriter, r *mux.Request) {
	RenderNode(w, jsonpage.Render(rd.store.Denoms(), r, nil))
}

func (rd *Renderer) Denom(w *mux.ResponseWriter, r *mux.Request) {
	denom := "ibc/" + r.GetVar("hash")
	d, found := rd.store.Denom(denom)
	if !found {
		RenderNode(w, NodeError(ufmt.Sprintf("denom %s not found", denom)))
		return
	}
	RenderNode(w, d.RenderJSON())
}

func (rd *Renderer) TotalEscrowForDenom(w *mux.ResponseWriter, r *mux.Request) {
	denom := r.GetVar("denom")
	// List the per-client amounts so the client/escrow binding is visible, not
	// just the aggregate. The total is kept at the top level for quick checks;
	// the client list is capped (see homeListLimit).
	clients := []*json.Node{}
	var total int64
	if v := rd.store.EscrowTotals().Get(denom); v != nil {
		total = v.(chain.Coin).Amount
	}
	rd.store.EscrowClients(denom).IterateByOffset(0, homeListLimit, func(clientID string, v any) bool {
		clients = append(clients, json.ObjectNode("", map[string]*json.Node{
			"client": json.StringNode("", clientID),
			"amount": json.NumberNode("", float64(v.(chain.Coin).Amount)),
		}))
		return false
	})
	RenderNode(w, json.ObjectNode("", map[string]*json.Node{
		"denom":   json.StringNode("", denom),
		"amount":  json.NumberNode("", float64(total)),
		"clients": json.ArrayNode("", clients),
	}))
}

func (rd *Renderer) Vouchers(w *mux.ResponseWriter, r *mux.Request) {
	RenderNode(w, jsonpage.Render(rd.store.Vouchers(), r, func(key string, v any) *json.Node {
		return VoucherJSON(key, v.(*grc20.Token))
	}))
}

func (rd *Renderer) Voucher(w *mux.ResponseWriter, r *mux.Request) {
	ibcDenom := "ibc/" + r.GetVar("hash")
	token := rd.store.VoucherToken(ibcDenom)
	if token == nil {
		RenderNode(w, NodeError("voucher token %s not found", ibcDenom))
		return
	}
	RenderNode(w, VoucherJSON(ibcDenom, token))
}

// VoucherJSON is the voucher/ibc/{hash} document, also the items of vouchers.
func VoucherJSON(ibcDenom string, token *grc20.Token) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"denom":        json.StringNode("", ibcDenom),
		"grc20reg_key": json.StringNode("", GRC20RegKey(ibcDenom)),
		"name":         json.StringNode("", token.GetName()),
		"symbol":       json.StringNode("", token.GetSymbol()),
		"decimals":     json.NumberNode("", float64(token.GetDecimals())),
		"total_supply": json.NumberNode("", float64(token.TotalSupply())),
	})
}

func (rd *Renderer) VoucherBalance(w *mux.ResponseWriter, r *mux.Request) {
	ibcDenom := "ibc/" + r.GetVar("hash")
	addr := r.GetVar("addr")
	token := rd.store.VoucherToken(ibcDenom)
	if token == nil {
		RenderNode(w, NodeError("voucher token %s not found", ibcDenom))
		return
	}
	balance := token.BalanceOf(address(addr))
	RenderNode(w, json.ObjectNode("", map[string]*json.Node{
		"denom":   json.StringNode("", ibcDenom),
		"address": json.StringNode("", addr),
		"balance": json.NumberNode("", float64(balance)),
	}))
}

// DenomsByClientOrder returns the first limit stored voucher denoms (in b+tree
// order) ordered to match the "Pick the client" listing (core.ClientIDsLimit
// order): each voucher is grouped under its source client (Trace[0].ClientId),
// following the same client order as the client list, so the vouchers table
// lines up with it. Within a client, the underlying b+tree order is preserved.
// Denoms whose source client is not in that listing (not or no longer
// registered, or beyond its cap) are appended last, in b+tree order, so none
// of the limit denoms is dropped. Every stored denom is a minted voucher with
// a non-empty trace, so Trace[0] is always safe to read.
func (rd *Renderer) DenomsByClientOrder(limit int) []ics20.Denom {
	denoms := rd.store.Denoms()
	byClient := make(map[string][]ics20.Denom)
	all := make([]ics20.Denom, 0, limit)
	denoms.IterateByOffset(0, limit, func(_ string, v any) bool {
		d := v.(ics20.Denom)
		all = append(all, d)
		client := d.Trace[0].ClientId
		byClient[client] = append(byClient[client], d)
		return false
	})

	out := make([]ics20.Denom, 0, len(all))
	emitted := make(map[string]bool) // source clients already emitted
	clientIDs, _ := core.ClientIDsLimit(homeListLimit)
	for _, client := range clientIDs {
		if ds, ok := byClient[client]; ok {
			out = append(out, ds...)
			emitted[client] = true
		}
	}
	for _, d := range all {
		if !emitted[d.Trace[0].ClientId] {
			out = append(out, d)
		}
	}
	return out
}

// RenderTransferLinks returns the "## Transfer" section: a set of txlinks
// that wallets can turn into MsgCalls to Transfer. Each link leaves at least
// one argument empty so the user fills it in their wallet.
func RenderTransferLinks() string {
	var out strings.Builder
	out.WriteString("## Transfer\n\n")

	clientIDs, total := core.ClientIDsLimit(homeListLimit)
	if total == 0 {
		out.WriteString("No IBC client registered yet — create one in [`/r/aib/ibc/core`](/r/aib/ibc/core) before transferring.\n\n")
		return out.String()
	}

	out.WriteString("Trigger an IBC transfer from your wallet. Pick the client of the destination chain:\n\n")
	for _, clientID := range clientIDs {
		status := core.ClientStatus(clientID)
		height := core.ClientLatestHeight(clientID)
		if core.IsClientRetiredFor(clientID, transfer.PortID) {
			// A retired client (ADR pr6375 §7.12) carries nothing more: its
			// status stays as it was, so it is checked first.
			out.WriteString(ufmt.Sprintf(
				"- `%s` — retired, trusted height `%s` ([client details](/r/aib/ibc/core:clients/%s))\n",
				clientID, height, clientID,
			))
		} else if status == lightclient.Active {
			out.WriteString(ufmt.Sprintf(
				"- [send via `%s`](%s) — %s, trusted height `%s` ([client details](/r/aib/ibc/core:clients/%s))\n",
				clientID, NewTransferLink(clientID, "", "").URL(), status, height, clientID,
			))
		} else {
			// Non-active client: no send link, since packets can't be sent.
			out.WriteString(ufmt.Sprintf(
				"- `%s` — %s, trusted height `%s` ([client details](/r/aib/ibc/core:clients/%s))\n",
				clientID, status, height, clientID,
			))
		}
	}
	if total > len(clientIDs) {
		out.WriteString(ufmt.Sprintf("\nFirst %d of %d clients; see [`clients`](/r/aib/ibc/core:clients) (`?page`, `?limit`) for all of them.\n", len(clientIDs), total))
	}

	out.WriteString("\n")
	return out.String()
}

// NewVoucherSendLink builds a txlink to VoucherSend with the ibc denom
// pre-filled. The user fills `to` and `amount` in their wallet.
func NewVoucherSendLink(ibcDenom string) *txlink.TxBuilder {
	return txlink.NewLink("VoucherSend").AddArgs(
		"ibcDenom", ibcDenom,
		"to", "",
		"amount", "",
	)
}

// NewVoucherApproveLink builds a txlink to VoucherApprove with the ibc denom
// pre-filled. The user fills `spender` and `amount` in their wallet.
func NewVoucherApproveLink(ibcDenom string) *txlink.TxBuilder {
	return txlink.NewLink("VoucherApprove").AddArgs(
		"ibcDenom", ibcDenom,
		"spender", "",
		"amount", "",
	)
}

// NewTransferLink builds a txlink to the Transfer function with the given
// pre-filled arguments. Empty values are left wallet-settable.
// timeoutTimestamp defaults to one hour from now (in unix seconds), matching
// what the e2e tests use; the user can still override it in their wallet.
func NewTransferLink(clientID, receiver, denom string) *txlink.TxBuilder {
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

// StripDomain removes the domain from a gno pkg path for use in URLs.
// "gno.land/r/demo/foo" → "/r/demo/foo"
func StripDomain(path string) string {
	i := strings.Index(path, "/")
	if i != -1 {
		return path[i:]
	}
	return path
}

// ShortDenom shortens an IBC denom hash for display.
// "ibc/CAEF9CABC…9D0F" (ibc/ + first 4 + … + last 4)
func ShortDenom(ibcDenom string) string {
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

// RenderNode writes n as JSON, inert in Markdown (jsonmd.Inert): its strings
// may carry a counterparty's base denom or a path segment of the request.
func RenderNode(w *mux.ResponseWriter, n *json.Node) {
	bz, err := json.Marshal(n)
	if err != nil {
		panic(err)
	}
	w.Write(jsonmd.Inert(string(bz)))
}

// GRC20RegKey returns the grc20reg key for a voucher ibc denom. grc20reg keys
// tokens by rlmPath.symbol, and a voucher's symbol is allocated when it is
// created (see transfer.VoucherSymbol), "" before.
// e.g. the first voucher → "gno.land/r/aib/ibc/apps/transfer.IBC-1"
func GRC20RegKey(ibcDenom string) string {
	return transfer.PkgPath + "." + transfer.VoucherSymbol(ibcDenom)
}

// NodeError is the JSON error object every route answers on failure.
func NodeError(msg string, args ...any) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"error": json.StringNode("", ufmt.Sprintf(msg, args...)),
	})
}

// RenderImplDisclosure is the upgradeable-realm notice of the home page.
func RenderImplDisclosure() string {
	return ufmt.Sprintf("**Upgradeable realm**: the ICS-20 logic runs in the implementation %s, replaceable by the authority with `UpdateImpl` (see [`admin`](/r/aib/ibc/apps/transfer:admin)).\n\n",
		RenderImplRef(transfer.ImplPath(), transfer.ImplVersion()))
}

func RenderImplRef(path, version string) string {
	if path == "" {
		return "none installed"
	}
	return ufmt.Sprintf("[`%s`](%s) (version %s)", path, StripDomain(path), version)
}
