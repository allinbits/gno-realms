package jsonpage

// ValidEscapes returns js, a JSON document, with the escapes in its string
// literals that JSON does not have rewritten as JSON escapes.
//
// The JSON encoder (gno.land/p/onbloc/json) quotes strings with
// strconv.Quote, which writes Go escapes: \a, \v, \xNN and \UNNNNNNNN. JSON
// parsers reject them, so a value a counterparty or a client creator chose
// (a base denomination, a chain id) holding a control character or an invalid
// UTF-8 byte made the whole document unparseable, for good since such values
// are stored. Control characters and runes keep their value (as \u escapes,
// or UTF-8 above U+FFFF); an invalid UTF-8 byte, which JSON cannot represent,
// becomes U+FFFD as encoding/json does.
func ValidEscapes(js []byte) []byte {
	out := make([]byte, 0, len(js))
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
		switch c {
		case '"':
			inString = false
			out = append(out, c)
		case '\\':
			if i+1 == len(js) {
				out = append(out, c)
				continue
			}
			i++
			switch e := js[i]; e {
			case 'a':
				out = appendUnicodeEscape(out, 0x07)
			case 'v':
				out = appendUnicodeEscape(out, 0x0b)
			case 'x':
				b, ok := parseHex(js, i+1, 2)
				if !ok {
					out = append(out, '\\', e)
					continue
				}
				i += 2
				if b < 0x80 {
					out = appendUnicodeEscape(out, b)
				} else {
					out = appendUnicodeEscape(out, 0xfffd)
				}
			case 'U':
				r, ok := parseHex(js, i+1, 8)
				if !ok {
					out = append(out, '\\', e)
					continue
				}
				i += 8
				if r > 0xffff {
					// As UTF-8: JSON allows it, and gno.land/p/onbloc/json
					// rejects the surrogate pair \u would need.
					out = append(out, string(rune(r))...)
				} else {
					out = appendUnicodeEscape(out, r)
				}
			default:
				// Escapes JSON shares with Go: \" \\ \b \f \n \r \t \u.
				out = append(out, '\\', e)
			}
		default:
			out = append(out, c)
		}
	}
	return out
}

// appendUnicodeEscape appends \uNNNN for r, which must be at most 0xffff.
func appendUnicodeEscape(out []byte, r uint32) []byte {
	const hex = "0123456789abcdef"
	return append(out, '\\', 'u', hex[r>>12&0xf], hex[r>>8&0xf], hex[r>>4&0xf], hex[r&0xf])
}

// parseHex parses the n hex digits of js starting at i.
func parseHex(js []byte, i, n int) (uint32, bool) {
	if i+n > len(js) {
		return 0, false
	}
	var v uint32
	for _, c := range js[i : i+n] {
		switch {
		case c >= '0' && c <= '9':
			v = v<<4 | uint32(c-'0')
		case c >= 'a' && c <= 'f':
			v = v<<4 | uint32(c-'a'+10)
		case c >= 'A' && c <= 'F':
			v = v<<4 | uint32(c-'A'+10)
		default:
			return 0, false
		}
	}
	return v, true
}
