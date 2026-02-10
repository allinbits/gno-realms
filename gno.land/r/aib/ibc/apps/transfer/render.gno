package transfer

import (
	"chain"

	"gno.land/p/aib/jsonpage"
	"gno.land/p/nt/mux"
	"gno.land/p/nt/ufmt"
	"gno.land/p/onbloc/json"
)

func Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("denoms", renderDenoms)
	router.HandleFunc("denoms/ibc/{hash}", renderDenom)
	router.HandleFunc("total_escrow/{denom}", renderTotalEscrowForDenom)
	router.HandleFunc("grc20/ibc/{hash}", renderGRC20)
	router.HandleFunc("grc20/ibc/{hash}/balance/{addr}", renderGRC20Balance)
	return router.Render(path)
}

func renderHome(w *mux.ResponseWriter, r *mux.Request) {
	// TODO list available endpoints ?
	w.Write(`["Hello IBC transfer!"]`)
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

func renderGRC20(w *mux.ResponseWriter, r *mux.Request) {
	ibcDenom := "ibc/" + r.GetVar("hash")
	inst := getGRC20(ibcDenom)
	if inst == nil {
		renderNode(w, nodeError("GRC20 token %s not found", ibcDenom))
		return
	}
	renderNode(w, json.ObjectNode("", map[string]*json.Node{
		"denom":        json.StringNode("", ibcDenom),
		"name":         json.StringNode("", inst.token.GetName()),
		"symbol":       json.StringNode("", inst.token.GetSymbol()),
		"decimals":     json.NumberNode("", float64(inst.token.GetDecimals())),
		"total_supply": json.NumberNode("", float64(inst.token.TotalSupply())),
	}))
}

func renderGRC20Balance(w *mux.ResponseWriter, r *mux.Request) {
	ibcDenom := "ibc/" + r.GetVar("hash")
	addr := r.GetVar("addr")
	inst := getGRC20(ibcDenom)
	if inst == nil {
		renderNode(w, nodeError("GRC20 token %s not found", ibcDenom))
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

func nodeError(msg string, args ...any) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"error": json.StringNode("", ufmt.Sprintf(msg, args...)),
	})
}
