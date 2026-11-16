package main

// SSZ hash_tree_root and Merkle helpers, written from the consensus specs
// (ssz/simple-serialize.md, ssz/merkle-proofs.md, phase0 and altair
// beacon-chain.md, deneb beacon-chain.md), independently of the gno client.

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

const chunk = 32

func sha(parts ...[]byte) []byte {
	h := sha256.New()
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

// zero is a zeroed chunk.
func zero() []byte { return make([]byte, chunk) }

// padRight pads b with zero bytes to a 32-byte chunk.
func padRight(b []byte) []byte {
	out := make([]byte, chunk)
	copy(out, b)
	return out
}

// uint64Leaf is the SSZ chunk of a uint64: little-endian, zero padded.
func uint64Leaf(v uint64) []byte {
	out := make([]byte, chunk)
	binary.LittleEndian.PutUint64(out, v)
	return out
}

// pack splits bytes into zero-padded chunks (at least one).
func pack(b []byte) [][]byte {
	var out [][]byte
	for i := 0; i < len(b); i += chunk {
		end := i + chunk
		if end > len(b) {
			end = len(b)
		}
		out = append(out, padRight(b[i:end]))
	}
	return out
}

// merkleize implements merkleize(chunks, limit): pad to the next power of
// two of limit with zero chunks and hash pairwise.
func merkleize(chunks [][]byte, limit int) []byte {
	width := 1
	for width < limit {
		width *= 2
	}
	layer := make([][]byte, width)
	for i := range layer {
		if i < len(chunks) {
			layer[i] = chunks[i]
		} else {
			layer[i] = zero()
		}
	}
	for len(layer) > 1 {
		next := make([][]byte, len(layer)/2)
		for i := range next {
			next[i] = sha(layer[2*i], layer[2*i+1])
		}
		layer = next
	}
	return layer[0]
}

func mixInLength(root []byte, n uint64) []byte { return sha(root, uint64Leaf(n)) }

// BeaconBlockHeader (phase0).
type beaconHeader struct {
	Slot, ProposerIndex             uint64
	ParentRoot, StateRoot, BodyRoot []byte
}

func (h beaconHeader) root() []byte {
	return merkleize([][]byte{uint64Leaf(h.Slot), uint64Leaf(h.ProposerIndex), h.ParentRoot, h.StateRoot, h.BodyRoot}, 5)
}

// ExecutionPayloadHeader (deneb; unchanged by electra and fulu).
type payloadHeader struct {
	ParentHash       []byte
	FeeRecipient     []byte // 20 bytes
	StateRoot        []byte
	ReceiptsRoot     []byte
	LogsBloom        []byte // 256 bytes
	PrevRandao       []byte
	BlockNumber      uint64
	GasLimit         uint64
	GasUsed          uint64
	Timestamp        uint64
	ExtraData        []byte // ByteList[32]
	BaseFeePerGas    uint64 // a uint256 here below 2^64
	BlockHash        []byte
	TransactionsRoot []byte
	WithdrawalsRoot  []byte
	BlobGasUsed      uint64
	ExcessBlobGas    uint64
}

// tree is hash_tree_root(ExecutionPayloadHeader) as a tree over its 17
// field roots. It is also the root of the ExecutionPayload it summarizes.
func (p payloadHeader) tree() *node {
	baseFee := make([]byte, chunk) // uint256 little-endian
	binary.LittleEndian.PutUint64(baseFee, p.BaseFeePerGas)
	extra := mixInLength(merkleize(pack(p.ExtraData), (presetMaxExtraDataBytes+chunk-1)/chunk), uint64(len(p.ExtraData))) // ByteList[MAX_EXTRA_DATA_BYTES]
	var fields []*node
	for _, f := range [][]byte{
		p.ParentHash, padRight(p.FeeRecipient), p.StateRoot, p.ReceiptsRoot,
		merkleize(pack(p.LogsBloom), presetBytesPerLogsBloom/chunk), p.PrevRandao,
		uint64Leaf(p.BlockNumber), uint64Leaf(p.GasLimit), uint64Leaf(p.GasUsed), uint64Leaf(p.Timestamp),
		extra, baseFee, p.BlockHash, p.TransactionsRoot, p.WithdrawalsRoot,
		uint64Leaf(p.BlobGasUsed), uint64Leaf(p.ExcessBlobGas),
	} {
		fields = append(fields, leaf(f))
	}
	return container(fields...)
}

func (p payloadHeader) root() []byte { return p.tree().root }

// pubkeyRoot is hash_tree_root(BLSPubkey): a Bytes48, two chunks.
func pubkeyRoot(pk []byte) []byte { return merkleize(pack(pk), 2) }

// pubkeysRoot is hash_tree_root(Vector[BLSPubkey, n]).
func pubkeysRoot(pks [][]byte) []byte {
	leaves := make([][]byte, len(pks))
	for i, pk := range pks {
		leaves[i] = pubkeyRoot(pk)
	}
	return merkleize(leaves, len(pks))
}

// pubkeyBranch is the Merkle branch of member i in the pubkeys vector,
// bottom-up (is_valid_merkle_branch order).
func pubkeyBranch(pks [][]byte, i int) [][]byte {
	layer := make([][]byte, len(pks))
	for j, pk := range pks {
		layer[j] = pubkeyRoot(pk)
	}
	var branch [][]byte
	for len(layer) > 1 {
		branch = append(branch, layer[i^1])
		next := make([][]byte, len(layer)/2)
		for j := range next {
			next[j] = sha(layer[2*j], layer[2*j+1])
		}
		layer, i = next, i/2
	}
	return branch
}

// syncCommitteeRoot is hash_tree_root(SyncCommittee{pubkeys, aggregate_pubkey}).
func syncCommitteeRoot(pks [][]byte, aggregate []byte) []byte {
	return merkleize([][]byte{pubkeysRoot(pks), pubkeyRoot(aggregate)}, 2)
}

// computeForkDataRoot, computeDomain and computeSigningRoot (phase0).
func computeDomain(domainType, forkVersion [4]byte, gvr []byte) []byte {
	forkDataRoot := merkleize([][]byte{padRight(forkVersion[:]), gvr}, 2)
	return append(append([]byte{}, domainType[:]...), forkDataRoot[:28]...)
}

func computeSigningRoot(objectRoot, domain []byte) []byte {
	return merkleize([][]byte{objectRoot, domain}, 2)
}

// node is a Merkle tree node. A node built from its children keeps them, so
// a branch can be read through it; an opaque node (a leaf, or the root of an
// unconstrained field such as a list or a signature) has none.
type node struct {
	root        []byte
	left, right *node
}

func leaf(b []byte) *node { return &node{root: b} }

func pair(l, r *node) *node { return &node{root: sha(l.root, r.root), left: l, right: r} }

// tree is merkleize over field roots, as a tree: padded with zero chunks to
// the next power of two of limit.
func tree(chunks []*node, limit int) *node {
	width := 1
	for width < limit {
		width *= 2
	}
	layer := make([]*node, width)
	for i := range layer {
		if i < len(chunks) {
			layer[i] = chunks[i]
		} else {
			layer[i] = leaf(zero())
		}
	}
	for len(layer) > 1 {
		next := make([]*node, len(layer)/2)
		for i := range next {
			next[i] = pair(layer[2*i], layer[2*i+1])
		}
		layer = next
	}
	return layer[0]
}

// progressiveTree is merkleize_progressive (EIP-7916, ssz-specs trees.py) as a
// tree: a right-leaning spine whose level n holds 4^(n-1) chunks, closed by a
// zero node.
func progressiveTree(chunks []*node, numLeaves int) *node {
	if len(chunks) == 0 {
		return leaf(zero())
	}
	n := numLeaves
	if n > len(chunks) {
		n = len(chunks)
	}
	return pair(tree(chunks[:n], numLeaves), progressiveTree(chunks[n:], numLeaves*4))
}

// container is hash_tree_root of a Container, as a tree.
func container(fields ...*node) *node { return tree(fields, len(fields)) }

// activeFieldsWord is the active-fields word of a progressive container
// whose n fields are all active: one bit per field, lowest bit first
// (ssz-specs mixins.py active_fields_word).
func activeFieldsWord(n int) []byte {
	out := make([]byte, chunk)
	for i := 0; i < n; i++ {
		out[i/8] |= 1 << uint(i%8)
	}
	return out
}

// progressiveContainer is hash_tree_root of a ProgressiveContainer with
// every field active (EIP-7495): the progressive root of its fields mixed
// with its active-fields word.
func progressiveContainer(fields ...*node) *node {
	return pair(progressiveTree(fields, 1), leaf(activeFieldsWord(len(fields))))
}

// zeroHash is the root of a tree of 2^depth zero chunks.
func zeroHash(depth int) []byte {
	h := zero()
	for i := 0; i < depth; i++ {
		h = sha(h, h)
	}
	return h
}

// emptyList is hash_tree_root of an empty List whose chunk limit is 2^depth:
// merkleize over no chunks at that limit, mixed with length 0.
func emptyList(depth int) *node { return leaf(mixInLength(zeroHash(depth), 0)) }

// emptyProgressiveList is hash_tree_root of an empty ProgressiveList
// (EIP-7916): merkleize_progressive of no chunks is the zero node, mixed with
// length 0, so SHA256(zero32 || zero32) (ssz-specs layout.py, trees.py).
func emptyProgressiveList() *node { return leaf(mixInLength(zero(), 0)) }

// at returns the node at gindex, which must be reachable through built nodes.
func (n *node) at(gindex uint64) *node {
	depth := 0
	for g := gindex; g > 1; g >>= 1 {
		depth++
	}
	cur := n
	for d := depth - 1; d >= 0; d-- {
		if cur.left == nil {
			panic(fmt.Sprintf("gindex %d goes through an opaque node", gindex))
		}
		if (gindex>>uint(d))&1 == 1 {
			cur = cur.right
		} else {
			cur = cur.left
		}
	}
	return cur
}

// branch is the bottom-up Merkle branch of the node at gindex.
func (n *node) branch(gindex uint64) [][]byte {
	var out [][]byte
	for g := gindex; g > 1; g >>= 1 {
		out = append(out, n.at(g^1).root)
	}
	return out
}

// normalize prepends zero chunks up to depth nodes, as normalize_merkle_branch.
func normalize(branch [][]byte, depth int) [][]byte {
	var out [][]byte
	for i := len(branch); i < depth; i++ {
		out = append(out, zero())
	}
	return append(out, branch...)
}
