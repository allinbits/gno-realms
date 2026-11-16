package jsonmd

import (
	"strings"
	"testing"
)

// u writes the expectations below: each ^ stands for a backslash-u escape.
func u(s string) string { return strings.ReplaceAll(s, "^", "\\"+"u") }

func TestQuote(t *testing.T) {
	cases := []struct{ in, want string }{
		{"plain", `"plain"`},
		{"[claim](https://attacker.example)", `"^005bclaim^005d^0028https://attacker.example^0029"`},
		{"<b>x</b> & `y` *z* #h !i |t ~s~", `"^003cb^003ex^003c/b^003e ^0026 ^0060y^0060 ^002az^002a ^0023h ^0021i ^007ct ^007es^007e"`},
		{"proven_at _x_", `"proven_at ^005fx^005f"`},
		{"$x$ $$y$$ @alice", `"^0024x^0024 ^0024^0024y^0024^0024 ^0040alice"`},
		{"q\"\\\n\x01", `"q^0022^005c^000a^0001"`},
		{string([]byte{0xc3, 0xa9, 0xe2, 0x80, 0xae, 0xf0, 0x9f, 0x98, 0x80, 0xff}), `"^00e9^202e^d83d^de00^fffd"`},
	}
	for _, c := range cases {
		if got := Quote(c.in); got != u(c.want) {
			t.Errorf("Quote(%q) = %s, want %s", c.in, got, u(c.want))
		}
	}
}

func TestInert(t *testing.T) {
	in := `{"to":"[claim](https://x.example)","esc":"a\"[b]\\","n":[1,2],"k_ey":null}`
	want := u(`{"to":"^005bclaim^005d^0028https://x.example^0029","esc":"a\"^005bb^005d\\","n":[1,2],"k_ey":null}`)
	if got := Inert(in); got != want {
		t.Errorf("Inert = %s\nwant    %s", got, want)
	}
}

// Markdown cells and inline text keep gnoweb's own extensions inert: a
// mention (@alice) and TeX math ($x$) in a token name a counterparty chose
// become character references (Codex round 35 #4), next to what sanitize
// escapes already.
func TestMarkdownCellAndText(t *testing.T) {
	cases := []struct{ in, cell, text string }{
		{"@alice", "&#64;alice", "&#64;alice"},
		{"$x$", "&#36;x&#36;", "&#36;x&#36;"},
		{"uatom", "uatom", "uatom"},
		{"a|b", `a\|b`, "a|b"},
	}
	for _, c := range cases {
		if got := Cell(c.in); got != c.cell {
			t.Errorf("Cell(%q) = %q, want %q", c.in, got, c.cell)
		}
		if got := Text(c.in); got != c.text {
			t.Errorf("Text(%q) = %q, want %q", c.in, got, c.text)
		}
	}
	for _, s := range []string{"@alice $x$", "[x](y) @b"} {
		for _, out := range []string{Cell(s), Text(s)} {
			for _, bad := range []string{"@", "$"} {
				if strings.Contains(out, bad) {
					t.Errorf("%q kept %q: %q", s, bad, out)
				}
			}
		}
	}
}
