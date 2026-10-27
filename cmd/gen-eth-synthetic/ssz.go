package main

// SSZ hash_tree_root and Merkle helpers, written from the consensus specs
// (ssz/simple-serialize.md, ssz/merkle-proofs.md, phase0 and altair
// beacon-chain.md, deneb beacon-chain.md), independently of the gno client.

import (
	"crypto/sha256"
	"encoding/binary"
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

func (p payloadHeader) root() []byte {
	baseFee := make([]byte, chunk) // uint256 little-endian
	binary.LittleEndian.PutUint64(baseFee, p.BaseFeePerGas)
	extra := mixInLength(merkleize(pack(p.ExtraData), 1), uint64(len(p.ExtraData))) // 32 bytes: one chunk limit
	return merkleize([][]byte{
		p.ParentHash, padRight(p.FeeRecipient), p.StateRoot, p.ReceiptsRoot,
		merkleize(pack(p.LogsBloom), 8), p.PrevRandao,
		uint64Leaf(p.BlockNumber), uint64Leaf(p.GasLimit), uint64Leaf(p.GasUsed), uint64Leaf(p.Timestamp),
		extra, baseFee, p.BlockHash, p.TransactionsRoot, p.WithdrawalsRoot,
		uint64Leaf(p.BlobGasUsed), uint64Leaf(p.ExcessBlobGas),
	}, 17)
}

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

// sparseTree is a Merkle tree known only along the paths to its leaves:
// every other node is an arbitrary filler chunk, so any set of leaves at
// generalized indices that are not ancestors of one another gets a
// consistent root and branches.
type sparseTree struct {
	leaves map[uint64][]byte
	filler func(gindex uint64) []byte
}

func newSparseTree(seed string) *sparseTree {
	return &sparseTree{leaves: map[uint64][]byte{}, filler: func(g uint64) []byte {
		return sha([]byte(seed), uint64Leaf(g))
	}}
}

func (t *sparseTree) set(gindex uint64, leaf []byte) { t.leaves[gindex] = leaf }

// onPath reports whether g is a leaf or an ancestor of one.
func (t *sparseTree) onPath(g uint64) bool {
	for l := range t.leaves {
		for x := l; x >= 1; x >>= 1 {
			if x == g {
				return true
			}
		}
	}
	return false
}

func (t *sparseTree) node(g uint64) []byte {
	if l, ok := t.leaves[g]; ok {
		return l
	}
	if !t.onPath(g) {
		return t.filler(g)
	}
	return sha(t.node(2*g), t.node(2*g+1))
}

func (t *sparseTree) root() []byte { return t.node(1) }

// branch is the bottom-up Merkle branch of the leaf at gindex.
func (t *sparseTree) branch(gindex uint64) [][]byte {
	var out [][]byte
	for g := gindex; g > 1; g >>= 1 {
		out = append(out, t.node(g^1))
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
