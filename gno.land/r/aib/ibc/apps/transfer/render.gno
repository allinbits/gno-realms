package transfer

import (
	"gno.land/p/nt/mux"
	"gno.land/p/nt/ufmt"
	"gno.land/p/onbloc/json"
)

func Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", RenderHome)
	router.HandleFunc("denoms", RenderDenoms)
	router.HandleFunc("denoms/ibc/{hash}", RenderDenom)
	return router.Render(path)
}

func RenderHome(w *mux.ResponseWriter, r *mux.Request) {
	// TODO list available endpoints ?
	w.Write(`["Hello IBC transfer!"]`)
}

func RenderDenoms(w *mux.ResponseWriter, r *mux.Request) {
	var nodes []*json.Node
	denomsByBase.Iterate("", "", func(key string, v any) bool {
		// TODO paginate
		nodes = append(nodes, renderDenom(v.(DenomMetadata)))
		return false
	})
	renderNode(w, json.ArrayNode("", nodes))
}

func RenderDenom(w *mux.ResponseWriter, r *mux.Request) {
	denom := "ibc/" + r.GetVar("hash")
	d, ok := denomsByBase.Get(denom)
	if !ok {
		renderNode(w, nodeError(ufmt.Sprintf("denom %s not found", denom)))
		return
	}
	renderNode(w, renderDenom(d.(DenomMetadata)))
}

func renderDenom(d DenomMetadata) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"base":        json.StringNode("", d.Base),
		"display":     json.StringNode("", d.Display),
		"symbol":      json.StringNode("", d.Symbol),
		"description": json.StringNode("", d.Description),
	})
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
