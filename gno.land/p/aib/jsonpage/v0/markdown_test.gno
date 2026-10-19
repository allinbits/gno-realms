package jsonpage

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/p/onbloc/json/v0"
)

func TestMarkdownSafe(t *testing.T) {
	testCases := []struct {
		name, in, expected string
	}{
		{
			"no strings",
			"{\"a\":[1,2],\"b\":true}",
			"{\"a\":[1,2],\"b\":true}",
		},
		{
			"plain value",
			"{\"base\":\"uatom\",\"path\":\"transfer/07-tendermint-1/uatom\"}",
			"{\"base\":\"uatom\",\"path\":\"transfer/07-tendermint-1/uatom\"}",
		},
		{
			"link and entity",
			"{\"base\":\"[send](&#47;r&#47;evil)\"}",
			"{\"base\":\"\\u005bsend\\u005d\\u0028\\u0026#47;r\\u0026#47;evil\\u0029\"}",
		},
		{
			"html, code, table, emphasis",
			"[\"<b>\",\"`x`\",\"a|b\",\"*x*~y~\"]",
			"[\"\\u003cb\\u003e\",\"\\u0060x\\u0060\",\"a\\u007cb\",\"\\u002ax\\u002a\\u007ey\\u007e\"]",
		},
		{
			"existing escapes kept",
			"{\"q\":\"say \\\"[hi]\\\" \\\\ é\"}",
			"{\"q\":\"say \\\"\\u005bhi\\u005d\\\" \\\\ é\"}",
		},
		{
			"structure untouched",
			"{\"items\":[{\"k\":\"(v)\"}],\"page\":1}",
			"{\"items\":[{\"k\":\"\\u0028v\\u0029\"}],\"page\":1}",
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			uassert.Equal(t, tc.expected, string(MarkdownSafe([]byte(tc.in))))
		})
	}
}

// MarkdownSafe changes the text of a string literal, never its value.
func TestMarkdownSafeKeepsValue(t *testing.T) {
	for _, v := range []string{
		"uatom",
		"[send](&#47;r&#47;evil$help&func=VoucherSend&to=a1)",
		"<b>`x`</b> a|b *x* ~y~",
		"quote \" backslash \\ unicode é",
	} {
		js, err := json.Marshal(json.StringNode("", v))
		urequire.NoError(t, err)
		got, ok := json.Unquote(MarkdownSafe(js), '"')
		urequire.True(t, ok)
		uassert.Equal(t, v, got)
	}
}
