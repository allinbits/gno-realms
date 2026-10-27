package main

import (
	"bytes"
	"os"
	"testing"
)

// The committed data file is what the generator writes.
func TestGeneratedFileIsCurrent(t *testing.T) {
	want, err := generate()
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile("../../gno.land/p/aib/ibc/lightclient/ethereum/v0/zz_synthetic_test.gno")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("zz_synthetic_test.gno is stale: regenerate it (see main.go)")
	}
}
