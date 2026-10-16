package ibcgov

import (
	"encoding/hex"
	"testing"
)

// The envelope prefix is fixed-width big-endian: version (1), epoch (4), seq
// (8), kind (1).
func TestEnvelope(t *testing.T) {
	b := Envelope(0x01020304, 0x05060708090a0b0c, 7, []byte{0xaa, 0xbb})
	want := "01" + "01020304" + "05060708090a0b0c" + "07" + "aabb"
	if hex.EncodeToString(b) != want {
		t.Fatalf("got %x", b)
	}
	e, seq, kind, params, ok := ParseEnvelope(b)
	if !ok || e != 0x01020304 || seq != 0x05060708090a0b0c || kind != 7 || hex.EncodeToString(params) != "aabb" {
		t.Fatalf("parse: %v %x %x %d %x", ok, e, seq, kind, params)
	}
	if _, _, _, _, ok := ParseEnvelope(b[:13]); ok {
		t.Fatalf("parsed a short envelope")
	}
	bad := append([]byte{}, b...)
	bad[0] = 2
	if _, _, _, _, ok := ParseEnvelope(bad); ok {
		t.Fatalf("parsed another version")
	}
}

func TestIdentifiers(t *testing.T) {
	for _, s := range []string{"inc-1", "a", "abcdefghijklmnopqrstuvwxyz012345"} {
		if !isIdent(s, 32) {
			t.Errorf("%q refused", s)
		}
	}
	for _, s := range []string{"", "Inc", "inc 1", "inc_1", "abcdefghijklmnopqrstuvwxyz0123456", "x\n"} {
		if isIdent(s, 32) {
			t.Errorf("%q accepted", s)
		}
	}
	for _, s := range []string{"ugnot", "ibc/ABCDEF", "gno.land:r:demo:foo.FOO", "0xAbC"} {
		if !isDenom(s) {
			t.Errorf("denom %q refused", s)
		}
	}
	for _, s := range []string{"", "u gnot", "a*b", "[x](y)"} {
		if isDenom(s) {
			t.Errorf("denom %q accepted", s)
		}
	}
}
