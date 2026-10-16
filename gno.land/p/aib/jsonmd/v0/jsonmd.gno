// Package jsonmd makes a JSON document safe to return from Render, whose
// output gnoweb parses as Markdown: every character of a string literal that
// Markdown or HTML could act on is written as a \uXXXX escape, so the page
// shows the data as inert text while a JSON parser reads exactly the same
// values. A realm's JSON pages carry user-controlled strings (an undecodable
// receiver kept on an owed sweep entry, a denom a counterparty chose, a path
// segment echoed in an error): without this, a string such as
// "[claim](https://attacker.example)" becomes a link on the realm's page.
package jsonmd

const hexDigits = "0123456789abcdef"

// Inert returns the JSON text doc with every Markdown- or HTML-active
// character inside its string literals escaped (see Quote). Text outside
// string literals (numbers, true, false, null, and the structure) is kept:
// it cannot form a link, an image, an autolink, raw HTML or emphasis. doc is
// expected to be valid JSON; a string left open runs to the end.
func Inert(doc string) string {
	out := make([]byte, 0, len(doc)+len(doc)/8)
	in := false
	for i := 0; i < len(doc); i++ {
		c := doc[i]
		if !in {
			out = append(out, c)
			if c == '"' {
				in = true
			}
			continue
		}
		switch {
		case c == '"':
			out = append(out, c)
			in = false
		case c == '\\' && i+1 < len(doc):
			// An escape sequence is kept as written: it is already inert
			// (a backslash before a letter or a quote).
			out = append(out, c, doc[i+1])
			i++
		case active(doc, i):
			out = appendU(out, rune(c))
		default:
			out = append(out, c)
		}
	}
	return string(out)
}

// Quote is s as a JSON string literal, inert in Markdown: the quote, the
// backslash, control characters and every Markdown- or HTML-active ASCII
// character are \u escapes, and so is every non-ASCII character (no bidi
// control or lookalike reaches the page). Invalid UTF-8 becomes U+FFFD. It
// decodes, as JSON, to s (with invalid UTF-8 replaced).
func Quote(s string) string {
	out := make([]byte, 0, len(s)+2)
	out = append(out, '"')
	for i, r := range s {
		switch {
		case r == '"' || r == '\\' || r < 0x20 || r >= 0x7f || active(s, i):
			out = appendU(out, r)
		default:
			out = append(out, byte(r))
		}
	}
	return string(append(out, '"'))
}

// active reports whether s[i], an ASCII byte, could take part in Markdown
// or HTML structure: links and images ([ ] ( ) !), code spans (`), emphasis
// and strikethrough (* ~, and an underscore not inside a word), raw HTML,
// autolinks and entities (< > &), headings (#) and table cells (|).
func active(s string, i int) bool {
	switch s[i] {
	case '`', '*', '[', ']', '(', ')', '~', '<', '>', '#', '!', '&', '|':
		return true
	case '_':
		return i == 0 || i+1 >= len(s) || !word(s[i-1]) || !word(s[i+1])
	}
	return false
}

func word(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// appendU appends r as one \uXXXX escape, or a UTF-16 surrogate pair.
func appendU(out []byte, r rune) []byte {
	if r > 0xffff {
		r -= 0x10000
		out = appendU(out, 0xd800+(r>>10)&0x3ff)
		return appendU(out, 0xdc00+r&0x3ff)
	}
	return append(out, '\\', 'u', hexDigits[r>>12&0xf], hexDigits[r>>8&0xf], hexDigits[r>>4&0xf], hexDigits[r&0xf])
}
