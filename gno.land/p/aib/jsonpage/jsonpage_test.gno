package jsonpage

import (
	"net/url"
	"strconv"
	"testing"

	"gno.land/p/nt/avl"
	"gno.land/p/nt/mux"
	"gno.land/p/nt/uassert"
	"gno.land/p/onbloc/json"
)

type String string

// Implements JSONRenderer
func (s String) RenderJSON() *json.Node {
	return json.StringNode("", string(s))
}

func TestRender(t *testing.T) {
	emptyTree := avl.NewTree()
	tree100 := avl.NewTree()
	for i := 0; i < 100; i++ {
		tree100.Set(strconv.Itoa(i), i)
	}
	tree150 := avl.NewTree()
	for i := 0; i < 150; i++ {
		tree150.Set(strconv.Itoa(i), i)
	}
	intRenderer := func(k string, v any) *json.Node {
		return json.NumberNode("", float64(v.(int)))
	}
	treeWithValueRenderer := avl.NewTree()
	for i := 0; i < 5; i++ {
		s := strconv.Itoa(i)
		treeWithValueRenderer.Set(s, String(s))
	}
	tests := []struct {
		name         string
		tree         *avl.Tree
		renderer     func(string, any) *json.Node
		query        string
		expectedJSON string
	}{
		{
			name:         "no query empty tree",
			tree:         emptyTree,
			renderer:     nil,
			query:        "",
			expectedJSON: `{"items":[],"page":1,"total":1}`,
		},
		{
			name:         "page=2 query empty tree",
			tree:         emptyTree,
			renderer:     nil,
			query:        "page=2",
			expectedJSON: `{"items":[],"page":2,"total":1}`,
		},
		{
			name:         "no query returns page 1",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "",
			expectedJSON: `{"items":[0,1,10,11,12,13,14,15,16,17,18,19,2,20,21,22,23,24,25,26],"page":1,"total":5}`,
		},
		{
			name:         "page 1",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=1",
			expectedJSON: `{"items":[0,1,10,11,12,13,14,15,16,17,18,19,2,20,21,22,23,24,25,26],"page":1,"total":5}`,
		},
		{
			name:         "page 0 returns page 1",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=0",
			expectedJSON: `{"items":[0,1,10,11,12,13,14,15,16,17,18,19,2,20,21,22,23,24,25,26],"page":1,"total":5}`,
		},
		{
			name:         "negative page returns page 1",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=-2",
			expectedJSON: `{"items":[0,1,10,11,12,13,14,15,16,17,18,19,2,20,21,22,23,24,25,26],"page":1,"total":5}`,
		},
		{
			name:         "page 2",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=2",
			expectedJSON: `{"items":[27,28,29,3,30,31,32,33,34,35,36,37,38,39,4,40,41,42,43,44],"page":2,"total":5}`,
		},
		{
			name:         "page == total returns last page",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=5",
			expectedJSON: `{"items":[81,82,83,84,85,86,87,88,89,9,90,91,92,93,94,95,96,97,98,99],"page":5,"total":5}`,
		},
		{
			name:         "page > total returns empty result",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=7",
			expectedJSON: `{"items":[],"page":7,"total":5}`,
		},
		{
			name:         "page 2 limit 10",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=2&limit=10",
			expectedJSON: `{"items":[18,19,2,20,21,22,23,24,25,26],"page":2,"total":10}`,
		},
		{
			name:         "page 2 limit 0 returns default limit",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=2&limit=0",
			expectedJSON: `{"items":[27,28,29,3,30,31,32,33,34,35,36,37,38,39,4,40,41,42,43,44],"page":2,"total":5}`,
		},
		{
			name:         "page 2 limit 100 return empty result",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "page=2&limit=100",
			expectedJSON: `{"items":[],"page":2,"total":1}`,
		},
		{
			name:         "page 1 limit 100 return all items",
			tree:         tree100,
			renderer:     intRenderer,
			query:        "limit=100",
			expectedJSON: `{"items":[0,1,10,11,12,13,14,15,16,17,18,19,2,20,21,22,23,24,25,26,27,28,29,3,30,31,32,33,34,35,36,37,38,39,4,40,41,42,43,44,45,46,47,48,49,5,50,51,52,53,54,55,56,57,58,59,6,60,61,62,63,64,65,66,67,68,69,7,70,71,72,73,74,75,76,77,78,79,8,80,81,82,83,84,85,86,87,88,89,9,90,91,92,93,94,95,96,97,98,99],"page":1,"total":1}`,
		},
		{
			name:         "max limit is 100",
			tree:         tree150,
			renderer:     intRenderer,
			query:        "limit=200",
			expectedJSON: `{"items":[0,1,10,100,101,102,103,104,105,106,107,108,109,11,110,111,112,113,114,115,116,117,118,119,12,120,121,122,123,124,125,126,127,128,129,13,130,131,132,133,134,135,136,137,138,139,14,140,141,142,143,144,145,146,147,148,149,15,16,17,18,19,2,20,21,22,23,24,25,26,27,28,29,3,30,31,32,33,34,35,36,37,38,39,4,40,41,42,43,44,45,46,47,48,49,5,50,51,52,53],"page":1,"total":2}`,
		},
		{
			name:         "page=2 max limit is 100",
			tree:         tree150,
			renderer:     intRenderer,
			query:        "limit=200&page=2",
			expectedJSON: `{"items":[54,55,56,57,58,59,6,60,61,62,63,64,65,66,67,68,69,7,70,71,72,73,74,75,76,77,78,79,8,80,81,82,83,84,85,86,87,88,89,9,90,91,92,93,94,95,96,97,98,99],"page":2,"total":2}`,
		},
		{
			name:         "value implements JSONRenderer",
			tree:         treeWithValueRenderer,
			renderer:     nil,
			query:        "",
			expectedJSON: `{"items":["0","1","2","3","4"],"page":1,"total":1}`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, err := url.ParseQuery(tt.query)
			if err != nil {
				t.Fatal(err)
			}
			r := &mux.Request{
				Query: v,
			}

			n := Render(tt.tree, r, tt.renderer)

			uassert.Equal(t, tt.expectedJSON, n.String())
		})
	}
}
