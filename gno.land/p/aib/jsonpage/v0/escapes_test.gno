package jsonpage

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/p/onbloc/json/v0"
)

func TestValidEscapes(t *testing.T) {
	testCases := []struct {
		name, in, expected string
	}{
		{
			"no escapes",
			`{"a":"uatom","b":[1,true]}`,
			`{"a":"uatom","b":[1,true]}`,
		},
		{
			"json escapes kept",
			`{"q":"say \"hi\" \\ \/ \b\f\n\r\t \u00e9"}`,
			`{"q":"say \"hi\" \\ \/ \b\f\n\r\t \u00e9"}`,
		},
		{
			"bell and vertical tab",
			`["\a","\v"]`,
			`["\u0007","\u000b"]`,
		},
		{
			"control byte",
			`["a\x01b","\x7f"]`,
			`["a\u0001b","\u007f"]`,
		},
		{
			"invalid utf-8 byte",
			`["u\xffatom"]`,
			`["u\ufffdatom"]`,
		},
		{
			"rune above U+FFFF",
			`["\U000e0001"]`,
			"[\"\U000e0001\"]",
		},
		{
			"escaped backslash before x",
			`["\\x01"]`,
			`["\\x01"]`,
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			uassert.Equal(t, tc.expected, string(ValidEscapes([]byte(tc.in))))
		})
	}
}

// What the encoder writes for any string becomes JSON that parses back to
// the same string, except invalid UTF-8 bytes, which become U+FFFD.
func TestValidEscapesParses(t *testing.T) {
	testCases := []struct{ in, expected string }{
		{"uatom", "uatom"},
		{"bell\a tab\v nul\x00 esc\x1b del\x7f", "bell\a tab\v nul\x00 esc\x1b del\x7f"},
		{"u\xffatom\xc3", "u\ufffdatom\ufffd"},
		{"tag \U000e0001 é", "tag \U000e0001 é"},
		{"quote \" backslash \\ newline \n", "quote \" backslash \\ newline \n"},
	}
	for _, tc := range testCases {
		js, err := json.Marshal(json.ObjectNode("", map[string]*json.Node{
			"v": json.StringNode("", tc.in),
		}))
		urequire.NoError(t, err)
		node, err := json.Unmarshal(ValidEscapes(js))
		urequire.NoError(t, err, string(js))
		v, err := node.MustKey("v").GetString()
		urequire.NoError(t, err)
		uassert.Equal(t, tc.expected, v)
	}
}
