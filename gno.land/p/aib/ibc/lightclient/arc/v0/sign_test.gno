package arc

import (
	"encoding/hex"
	"testing"
)

// TestPrecommitSignBytes pins the layout against a precommit of Arc testnet
// block 70498732 (arc_getCertificate), whose signature verifies over it.
func TestPrecommitSignBytes(t *testing.T) {
	hash, _ := hex.DecodeString("129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685")
	addr, _ := hex.DecodeString("feb2b98d614701434ea6a12ccf29e0e40ae56941")
	got := hex.EncodeToString(precommitSignBytes(70498732, 0, hash, addr))
	want := "01acb9330400000000" + "25000000" + "2a000000" + "feb2b98d614701434ea6a12ccf29e0e40ae56941" +
		"0100000000" + "01" + "129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685"
	if got != want {
		t.Fatalf("sign bytes\n got %s\nwant %s", got, want)
	}
}

func TestSlotAdd(t *testing.T) {
	s, _ := hex.DecodeString("00000000000000000000000000000000000000000000000000000000000000ff")
	if got := hex.EncodeToString(slotAdd(s, 1)); got != "0000000000000000000000000000000000000000000000000000000000000100" {
		t.Fatal(got)
	}
	m, _ := hex.DecodeString("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
	if got := hex.EncodeToString(slotAdd(m, 2)); got != "0000000000000000000000000000000000000000000000000000000000000001" {
		t.Fatal(got)
	}
	if got := hex.EncodeToString(slotAdd(s, 0x0102)); got != "0000000000000000000000000000000000000000000000000000000000000201" {
		t.Fatal(got)
	}
}
