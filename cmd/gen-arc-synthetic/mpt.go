package main

// A Merkle-Patricia trie builder (yellow paper, appendix D) with
// eth_getProof-style proofs: the nodes on a key's path from the root, each
// node encoded in 32 bytes or more once (shorter ones are embedded in their
// parent, as the trie embeds them). Written from the yellow paper, not from
// the gno client's verifier; TestTrieVectors checks it against vectors of
// ethereum/tests (TrieTests/trietest.json, trieanyorder.json).

import (
	"bytes"
	"sort"
)

type trieNode struct {
	// A leaf or extension has a path; a branch has children (and a value
	// when a key ends at it). A leaf has a value, an extension one child.
	path     []byte
	value    []byte
	child    *trieNode
	children [16]*trieNode
	branch   bool
}

type trieEntry struct{ path, value []byte }

func nibbles(b []byte) []byte {
	n := make([]byte, 0, 2*len(b))
	for _, c := range b {
		n = append(n, c>>4, c&0x0f)
	}
	return n
}

// hexPrefix is the compact (hex-prefix) encoding of a nibble path.
func hexPrefix(path []byte, leaf bool) []byte {
	flag := byte(0)
	if leaf {
		flag = 2
	}
	var out []byte
	if len(path)%2 == 1 {
		out = append(out, (flag+1)<<4|path[0])
		path = path[1:]
	} else {
		out = append(out, flag<<4)
	}
	for i := 0; i < len(path); i += 2 {
		out = append(out, path[i]<<4|path[i+1])
	}
	return out
}

// buildTrie builds the trie of entries, whose paths are distinct; nil when
// there are none.
func buildTrie(entries []trieEntry) *trieNode {
	sort.Slice(entries, func(i, j int) bool { return bytes.Compare(entries[i].path, entries[j].path) < 0 })
	return build(entries)
}

func build(entries []trieEntry) *trieNode {
	switch len(entries) {
	case 0:
		return nil
	case 1:
		return &trieNode{path: entries[0].path, value: entries[0].value}
	}
	// The longest prefix every path shares.
	prefix := entries[0].path
	for _, e := range entries[1:] {
		n := 0
		for n < len(prefix) && n < len(e.path) && prefix[n] == e.path[n] {
			n++
		}
		prefix = prefix[:n]
	}
	if len(prefix) > 0 {
		rest := make([]trieEntry, len(entries))
		for i, e := range entries {
			rest[i] = trieEntry{e.path[len(prefix):], e.value}
		}
		return &trieNode{path: prefix, child: build(rest)}
	}
	b := &trieNode{branch: true}
	var groups [16][]trieEntry
	for _, e := range entries {
		if len(e.path) == 0 {
			b.value = e.value
			continue
		}
		groups[e.path[0]] = append(groups[e.path[0]], trieEntry{e.path[1:], e.value})
	}
	for i, g := range groups {
		b.children[i] = build(g)
	}
	return b
}

// encode is the node's RLP.
func (n *trieNode) encode() []byte {
	if n.branch {
		items := make([][]byte, 17)
		for i, c := range n.children {
			items[i] = ref(c)
		}
		items[16] = rlpBytes(n.value)
		return rlpList(items...)
	}
	if n.child == nil {
		return rlpList(rlpBytes(hexPrefix(n.path, true)), rlpBytes(n.value))
	}
	return rlpList(rlpBytes(hexPrefix(n.path, false)), ref(n.child))
}

// ref is how a parent refers to n: empty for none, the node itself when its
// encoding is under 32 bytes, its hash otherwise.
func ref(n *trieNode) []byte {
	if n == nil {
		return rlpBytes(nil)
	}
	enc := n.encode()
	if len(enc) < 32 {
		return enc
	}
	return rlpBytes(keccak(enc))
}

// trieRoot is the root hash, keccak(rlp("")) for an empty trie.
func trieRoot(n *trieNode) []byte {
	if n == nil {
		return keccak(rlpBytes(nil))
	}
	return keccak(n.encode())
}

// prove is the proof of path: the nodes walked from the root until the
// path's value or the point where the trie shows it absent, the root always
// and every other node only when it is hashed (32 bytes or more).
func prove(root *trieNode, path []byte) [][]byte {
	if root == nil {
		return nil
	}
	proof := [][]byte{root.encode()}
	n := root
	for {
		var next *trieNode
		switch {
		case n.branch:
			if len(path) == 0 {
				return proof
			}
			next, path = n.children[path[0]], path[1:]
		case n.child == nil: // leaf
			return proof
		default: // extension
			if len(path) < len(n.path) || !bytes.Equal(path[:len(n.path)], n.path) {
				return proof
			}
			next, path = n.child, path[len(n.path):]
		}
		if next == nil {
			return proof
		}
		if enc := next.encode(); len(enc) >= 32 {
			proof = append(proof, enc)
		}
		n = next
	}
}

// secureTrie is a state or storage trie: keys are hashed.
type secureTrie struct {
	values map[string][]byte
	root   *trieNode
}

func newSecureTrie() *secureTrie { return &secureTrie{values: map[string][]byte{}} }

func (t *secureTrie) set(key, value []byte) {
	t.values[string(key)] = value
	t.root = nil
}

func (t *secureTrie) build() *trieNode {
	if t.root == nil {
		var entries []trieEntry
		for k, v := range t.values {
			entries = append(entries, trieEntry{nibbles(keccak([]byte(k))), v})
		}
		t.root = buildTrie(entries)
	}
	return t.root
}

func (t *secureTrie) hash() []byte { return trieRoot(t.build()) }

func (t *secureTrie) prove(key []byte) [][]byte { return prove(t.build(), nibbles(keccak(key))) }

// storage is an account's storage: 32-byte slots holding 32-byte words,
// stored as the RLP of the word without its leading zeros, a zero word not
// at all.
type storage struct{ *secureTrie }

func newStorage() storage { return storage{newSecureTrie()} }

func (s storage) setWord(slot, word []byte) {
	if len(slot) != 32 || len(word) != 32 {
		panic("storage slots and words are 32 bytes")
	}
	trimmed := bytes.TrimLeft(word, "\x00")
	if len(trimmed) == 0 {
		delete(s.values, string(slot))
		s.root = nil
		return
	}
	s.set(slot, rlpBytes(trimmed))
}

// account is the state trie value of an account.
func account(nonce, balance uint64, storageRoot, codeHash []byte) []byte {
	return rlpList(rlpUint(nonce), rlpUint(balance), rlpBytes(storageRoot), rlpBytes(codeHash))
}
