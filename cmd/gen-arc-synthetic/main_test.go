package main

import (
	"bytes"
	"encoding/hex"
	"os"
	"testing"
)

// The committed data file is what the generator writes.
func TestGeneratedFileIsCurrent(t *testing.T) {
	want, err := generate()
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile("../../gno.land/p/aib/ibc/lightclient/arc/v0/zz_synthetic_test.gno")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("zz_synthetic_test.gno is stale: regenerate it (see main.go)")
	}
}

// Root hashes of ethereum/tests TrieTests (trietest.json, trieanyorder.json;
// go-ethereum's trie gives the same), plain (unhashed) keys: extensions,
// branches with values, embedded and hashed nodes.
func TestTrieVectors(t *testing.T) {
	for _, tc := range []struct {
		name string
		kv   [][2]string
		root string
	}{
		{"emptyValues", nil, "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"},
		{"dogs", [][2]string{{"doe", "reindeer"}, {"dog", "puppy"}, {"dogglesworth", "cat"}}, "8aad789dff2f538bca5d8ea56e8abe10f4c7ba3a5dea95fea4cd6e7c3a1168d3"},
		{"puppy", [][2]string{{"do", "verb"}, {"horse", "stallion"}, {"doge", "coin"}, {"dog", "puppy"}}, "5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84"},
		{"foo", [][2]string{{"foo", "bar"}, {"food", "bass"}}, "17beaa1648bafa633cda809c90c04af50fc8aed3cb40d16efbddee6fdf63c4c3"},
	} {
		var entries []trieEntry
		for _, e := range tc.kv {
			entries = append(entries, trieEntry{nibbles([]byte(e[0])), []byte(e[1])})
		}
		if got := hex.EncodeToString(trieRoot(buildTrie(entries))); got != tc.root {
			t.Errorf("%s: root %s, want %s", tc.name, got, tc.root)
		}
	}
}

// The sign bytes of a live precommit of Arc testnet block 70498732
// (arc_getCertificate), whose signature verifies over them.
func TestSignBytes(t *testing.T) {
	hash := mustHex("129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685")
	addr := mustHex("feb2b98d614701434ea6a12ccf29e0e40ae56941")
	want := "01acb9330400000000" + "25000000" + "2a000000" + "feb2b98d614701434ea6a12ccf29e0e40ae56941" +
		"0100000000" + "01" + "129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685"
	if got := hex.EncodeToString(signBytes(70498732, 0, hash, addr)); got != want {
		t.Fatalf("sign bytes\n got %s\nwant %s", got, want)
	}
}

// The ERC-1967 implementation slot, as EIP-1967 states it.
func TestImplementationSlot(t *testing.T) {
	if got := hex.EncodeToString(erc1967Implementation); got != "360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" {
		t.Fatal(got)
	}
}

// The sets give the cases the Gno tests name: T's total is 9 (trust level
// 1/3: more than 3 trusted power), the rotated set's 15 (more than 10), the
// reweighted set's 12 (more than 8); the zero-power key 8 is in none, and
// the rotation's swap-and-pop removal orders the set as the registry does.
func TestSets(t *testing.T) {
	c := newChain()
	total := func(ms []member) (s uint64) {
		for _, m := range ms {
			s += m.power
		}
		return s
	}
	if total(c.trusted) != 9 || total(c.rotated) != 15 || total(c.reweighted) != 12 {
		t.Fatalf("totals %d %d %d", total(c.trusted), total(c.rotated), total(c.reweighted))
	}
	order := func(ms []member) (keys []int) {
		for _, m := range ms {
			keys = append(keys, m.key)
		}
		return keys
	}
	// Registrations 1-6 are keys 0-5, 7 is key 8 (no power): removing 5
	// moves 7 to its place, removing 6 pops it; 6 and 7 are appended.
	if got := order(c.rotated); !equalInts(got, []int{0, 1, 2, 3, 6, 7}) {
		t.Fatalf("rotated order %v", got)
	}
	if got := c.rotation.reg.active; len(got) != 7 || got[4] != 7 {
		t.Fatalf("active registrations %v", got)
	}
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
