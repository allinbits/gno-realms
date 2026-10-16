package ethaddr

import (
	"strings"
	"testing"
)

// The checksummed addresses are the test vectors of EIP-55.
var eip55Vectors = []string{
	"0x52908400098527886E0F7030069857D2E4169EE7",
	"0x8617E340B3D01FA5F11F306F4090FD50E238070D",
	"0xde709f2102306220921060314715629080e2fb77",
	"0x27b1fdb04752bbc536007a920d24acb045561c26",
	"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
	"0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
	"0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
	"0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
}

func TestEIP55(t *testing.T) {
	for _, v := range eip55Vectors {
		a, err := Parse(v)
		if err != nil {
			t.Fatalf("%s: %v", v, err)
		}
		if a.String() != v {
			t.Errorf("String: got %s want %s", a.String(), v)
		}
		if a.Lower() != strings.ToLower(v) {
			t.Errorf("Lower: got %s", a.Lower())
		}
		for _, form := range []string{strings.ToLower(v), "0x" + strings.ToUpper(v[2:])} {
			b, err := Parse(form)
			if err != nil || b != a {
				t.Errorf("%s: %v", form, err)
			}
		}
	}
}

func TestParseRefuses(t *testing.T) {
	cases := []string{
		"",
		"0x",
		"5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
		" 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAe",
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAedd",
		"0X5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeg",
		"0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed", // one letter's case wrong
		"0x000000000000000000000000000000000000000000000000000000000000dead",
	}
	for _, c := range cases {
		if _, err := Parse(c); err == nil {
			t.Errorf("%q parsed", c)
		}
	}
}

func TestZeroAndReserved(t *testing.T) {
	z, err := Parse("0x0000000000000000000000000000000000000000")
	if err != nil || !z.IsZero() || !z.Reserved() {
		t.Fatalf("zero: %v %v %v", err, z.IsZero(), z.Reserved())
	}
	p, _ := Parse("0x000000000000000000000000000000000000ffff")
	if p.IsZero() || !p.Reserved() {
		t.Errorf("0xffff must be reserved")
	}
	q, _ := Parse("0x0000000000000000000000000000000000010000")
	if q.Reserved() {
		t.Errorf("0x10000 is not reserved")
	}
}
