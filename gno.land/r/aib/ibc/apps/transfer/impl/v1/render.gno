package impl

import (
	"strings"

	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
)

// Render serves impl/v0's routes and the route controls' JSON for monitors
// and tooling (ADR pr6375 §7.11):
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
		w.Write(l.reader().RouteJSON(r.GetVar("route")))
	})
	router.HandleFunc("routes/{route}/claims", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(l.reader().ClaimsJSON(r.GetVar("route"), r.Query.Get("from")))
	})
	router.HandleFunc("routes/{route}/sweeps", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(l.reader().SweepsJSON(r.GetVar("route"), r.Query.Get("from")))
	})
	router.HandleFunc("routes/{route}/sends", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(l.reader().SendsJSON(r.GetVar("route"), r.Query.Get("from")))
	})
	router.HandleFunc("routes/{route}/losses", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write(l.reader().LossesJSON(r.GetVar("route"), r.Query.Get("from")))
	})
	implv0.NewRenderer(l.store).Register(router)
	return router.Render(path)
}

// home is impl/v0's home page with the routes under control.
func (l *logic) home(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	v0 := mux.NewRouter()
	implv0.NewRenderer(l.store).Register(v0)
	out.WriteString(v0.Render(""))
	out.WriteString("\n## Ethereum routes\n\n")
	keys := l.reader().Routes()
	if len(keys) == 0 {
		out.WriteString("No route enrolled: Ethereum clients carry no transfer.\n")
	}
	for _, k := range keys {
		// Route keys and denoms are client ids and checked denoms; the JSON
		// route holds everything else.
		out.WriteString(ufmt.Sprintf("- `%s` (client `%s`): denoms %s, see [routes/%s](:routes/%s)\n",
			k, l.reader().Client(k), strings.Join(l.reader().Denoms(k), ", "), k, k))
	}
	w.Write(out.String())
}
