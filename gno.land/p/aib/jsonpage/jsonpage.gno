package jsonpage

import (
	"strconv"

	"gno.land/p/nt/avl"
	"gno.land/p/nt/mux"
	"gno.land/p/onbloc/json"
)

type JSONRenderer interface {
	RenderJSON() *json.Node
}

const (
	maxLimit     = 100
	defaultLimit = 20
)

// Render returns a paginated JSON output.
// CONTRACT: provide non-nil renderer func or values from the avl.Tree must
// implement JSONRenderer.
func Render(t avl.ITree, r *mux.Request, renderer func(string, any) *json.Node) *json.Node {
	var (
		page  = 1
		limit = defaultLimit
	)
	p, err := strconv.Atoi(r.Query.Get("page"))
	if err == nil && p > 0 {
		page = p
	}
	l, err := strconv.Atoi(r.Query.Get("limit"))
	if err == nil && l > 0 {
		limit = l
	}
	return render(t, page, limit, renderer, false)
}

func render(t avl.ITree, page, limit int, renderer func(string, any) *json.Node, reverse bool) *json.Node {
	total := t.Size()
	if limit == 0 || limit > total {
		limit = total
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	var (
		offset  = (page - 1) * limit
		items   []*json.Node
		iterate = t.IterateByOffset
	)
	if reverse {
		iterate = t.ReverseIterateByOffset
	}
	iterate(offset, limit, func(k string, v any) bool {
		if renderer != nil {
			items = append(items, renderer(k, v))
		} else {
			items = append(items, v.(JSONRenderer).RenderJSON())
		}
		return false
	})
	totalPages := 1
	if limit > 0 {
		totalPages = (total + limit - 1) / limit
	}
	return json.ObjectNode("", map[string]*json.Node{
		"items": json.ArrayNode("", items),
		"page":  json.NumberNode("", float64(page)),
		"total": json.NumberNode("", float64(totalPages)),
	})
}
