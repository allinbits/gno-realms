package jsonpage

// MarkdownSafe returns js, a JSON document, with every character of its
// string literals that markdown could interpret as a link, an HTML tag or
// entity, code or a table cell written as a \u escape. The document still
// decodes to exactly the same value; only its text changes.
//
// gnoweb renders whatever a realm's Render returns as markdown, JSON pages
// included, and JSON string encoding leaves those characters as is. Values a
// counterparty or a URL provided (an ICS-20 base denomination, a path
// segment echoed in an error) could otherwise show up as live links or
// markup on the realm's pages.
func MarkdownSafe(js []byte) []byte {
	// Allocate the most the output can take, 6 bytes per input byte: gno's
	// append grows a slice to exactly the length it needs, so once the
	// escapes had filled the input's length, every append copied the whole
	// output again, a cost quadratic in the input.
	out := make([]byte, 0, 6*len(js))
	inString := false
	for i := 0; i < len(js); i++ {
		c := js[i]
		if !inString {
			if c == '"' {
				inString = true
			}
			out = append(out, c)
			continue
		}
		switch {
		case c == '\\':
			// Keep existing escapes as they are, including the escaped
			// character, so an escaped quote does not end the string.
			out = append(out, c)
			if i+1 < len(js) {
				i++
				out = append(out, js[i])
			}
		case c == '"':
			inString = false
			out = append(out, c)
		case markdownSignificant(c):
			const hex = "0123456789abcdef"
			out = append(out, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xf])
		default:
			out = append(out, c)
		}
	}
	return out
}

func markdownSignificant(c byte) bool {
	switch c {
	case '[', ']', '(', ')', '<', '>', '&', '`', '|', '*', '~':
		return true
	}
	return false
}
