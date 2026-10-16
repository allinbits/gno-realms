package impl

import (
	"strings"

	"gno.land/p/aib/jsonmd/v0"
	"gno.land/p/nt/markdown/sanitize/v0"

	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
)

// Render serves impl/v0's routes and the route controls' JSON for monitors
// and tooling (ADR pr6375 §7.11), every JSON page inert in Markdown
// (jsonmd.Inert: an owed sweep entry keeps a raw, attacker-chosen receiver):
//
//	routes                       every route
//	routes/{route}               a route: client, fee collector, refused
//	                             recipients, and per denom its configuration,
//	                             meters and accounting terms
//	routes/{route}/claims        claims by packet key (?from=<key>)
//	routes/{route}/sweeps        sweep entries (?from=<key>)
//	routes/{route}/sends         send records with their outcomes (?from=<key>)
//	routes/{route}/losses        the loss ledger (?from=<key>)
func (l *logic) Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", l.home)
	router.HandleFunc("routes", func(w *mux.ResponseWriter, r *mux.Request) { w.Write(l.reader().RoutesJSON()) })
	router.HandleFunc("routes/{route}", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(jsonmd.Inert(l.reader().RouteJSON(r.GetVar("route"))))
	})
	router.HandleFunc("routes/{route}/claims", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(jsonmd.Inert(l.reader().ClaimsJSON(r.GetVar("route"), r.Query.Get("from"))))
	})
	router.HandleFunc("routes/{route}/sweeps", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(jsonmd.Inert(l.reader().SweepsJSON(r.GetVar("route"), r.Query.Get("from"))))
	})
	router.HandleFunc("routes/{route}/sends", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(jsonmd.Inert(l.reader().SendsJSON(r.GetVar("route"), r.Query.Get("from"))))
	})
	router.HandleFunc("routes/{route}/losses", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(jsonmd.Inert(l.reader().LossesJSON(r.GetVar("route"), r.Query.Get("from"))))
	})
	implv0.NewRenderer(l.store).Register(router)
	return router.Render(path)
}

// home is impl/v0's home page with the routes under control.
func (l *logic) home(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	v0 := mux.NewRouter()
	rd := implv0.NewRenderer(l.store)
	rd.Register(v0)
	out.WriteString(l.routeLinks(rd, v0.Render("")))
	out.WriteString("\n## Ethereum routes\n\n")
	keys := l.reader().Routes()
	if len(keys) == 0 {
		out.WriteString("No route enrolled: Ethereum clients carry no transfer.\n")
	}
	for _, k := range keys {
		// Route keys are client ids the core made; denoms are written
		// escaped all the same, and the JSON route holds everything else.
		out.WriteString(ufmt.Sprintf("- `%s` (client `%s`): denoms %s, see [routes/%s](:routes/%s)\n",
			k, l.reader().Client(k), sanitize.InlineText(strings.Join(l.reader().Denoms(k), ", ")), k, k))
	}
	w.Write(out.String())
}

// routeLinks rewrites impl/v0's "send back" links of the vouchers of a route
// whose client a replacement retired (ADR pr6375 §7.12, Codex review #18):
// v0 builds them from the voucher's first trace hop, the route key, which
// names the retired client. They go through the route's current client
// instead, or are withdrawn while the route is closed.
func (l *logic) routeLinks(rd *implv0.Renderer, page string) string {
	rdr := l.reader()
	for _, d := range rd.DenomsByClientOrder() {
		key := d.Trace[0].ClientId
		current := rdr.Client(key)
		if current == "" || current == key && !rdr.Closed(key) {
			continue
		}
		ibcDenom := d.IBCDenom()
		old := ufmt.Sprintf("[send back](%s) via `%s`", implv0.NewTransferLink(key, "", ibcDenom).URL(), key)
		repl := ufmt.Sprintf("[send back](%s) via `%s`", implv0.NewTransferLink(current, "", ibcDenom).URL(), current)
		if rdr.Closed(key) {
			repl = ufmt.Sprintf("send back closed (route `%s` awaits its reopening)", key)
		}
		page = strings.ReplaceAll(page, old, repl)
	}
	return page
}
