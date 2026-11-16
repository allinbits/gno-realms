package controls

import (
	"strings"

	"gno.land/p/aib/jsonmd/v0"

	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	ics20impl "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v0"
)

// Render serves the plain app's routes and the route controls' JSON for monitors
// and tooling (ADR pr6375 §7.11), every JSON page inert in Markdown
// (jsonmd.Inert: an owed sweep entry keeps a raw, attacker-chosen receiver):
//
//	routes                       every route
//	routes/{route}               a route: client, fee collector, refused
//	                             recipients, and per denom its configuration,
//	                             meters and accounting terms
//	routes/{route}/claims        claims by packet key
//	routes/{route}/sweeps        sweep entries by packet key
//	routes/{route}/sends         send records with their outcomes, by packet key
//	routes/{route}/losses        the loss ledger, by direction and packet key
//
// Each of the last four is a page {"entries":[...],"next":<cursor>}: pass
// next as ?from= for the following page ("" when there is none).
func (l *routes) Render(path string) string {
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
	l.renderer().Register(router)
	return router.Render(path)
}

// home is the plain app's home page, each voucher of a route sent back
// through the route's current client, with the routes under control.
func (l *routes) home(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	v0 := mux.NewRouter()
	l.renderer().Register(v0)
	out.WriteString(v0.Render(""))
	out.WriteString("\n## Ethereum routes\n\n")
	keys := l.reader().Routes()
	if len(keys) == 0 {
		out.WriteString("No route enrolled: Ethereum clients carry no transfer.\n")
	}
	for _, k := range keys {
		// Route keys are client ids the core made; denoms are written
		// escaped all the same, and the JSON route holds everything else.
		out.WriteString(ufmt.Sprintf("- `%s` (client `%s`): denoms %s, see [routes/%s](:routes/%s)\n",
			k, l.reader().Client(k), jsonmd.Text(strings.Join(l.reader().Denoms(k), ", ")), k, k))
	}
	w.Write(out.String())
}

// renderer is the plain app's Renderer, its "send back" link of a voucher of
// a route whose client a replacement retired (ADR pr6375 §7.12, Codex review
// #18) going through the route's current client: the voucher's first trace
// hop is the route key, which names the retired client. A closed route's
// too: a voucher return is exit only, taken while the route awaits its
// reopening (ADR pr6375 §7.12).
func (l *routes) renderer() *ics20impl.Renderer {
	rdr := l.reader()
	return ics20impl.NewRendererVia(l.store, func(firstHop string) string { return rdr.Client(firstHop) })
}
