package ethereum

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
)

// SSZ hash_tree_root helpers, restricted to the containers the light client
// hashes. See https://github.com/ethereum/consensus-specs/blob/dev/ssz/simple-serialize.md

const chunkSize = 32

// maxZeroHashDepth bounds the merkleization depth used here: the largest
// tree is a 512-key sync committee (depth 9).
const maxZeroHashDepth = 16

// zeroHashes[i] is the root of a tree of 2^i zero chunks.
var zeroHashes [maxZeroHashDepth + 1][]byte

func init() {
	zeroHashes[0] = make([]byte, chunkSize)
	for i := 1; i <= maxZeroHashDepth; i++ {
		zeroHashes[i] = hash2(zeroHashes[i-1], zeroHashes[i-1])
	}
}

// hash2 returns sha256(a || b).
func hash2(a, b []byte) []byte {
	buf := make([]byte, 0, len(a)+len(b))
	buf = append(buf, a...)
	buf = append(buf, b...)
	h := sha256.Sum256(buf)
	return h[:]
}

// merkleize returns the root of chunks padded with zero chunks to the next
// power of two of limit leaves. len(chunks) must not exceed limit.
func merkleize(chunks [][]byte, limit int) []byte {
	if len(chunks) > limit {
		panic("ssz: more chunks than the limit")
	}
	depth := 0
	for (1 << depth) < limit {
		depth++
	}
	if depth > maxZeroHashDepth {
		panic("ssz: tree too deep")
	}
	if len(chunks) == 0 {
		return zeroHashes[depth]
	}
	layer := chunks
	for d := 0; d < depth; d++ {
		next := make([][]byte, (len(layer)+1)/2)
		for i := 0; i < len(layer); i += 2 {
			right := zeroHashes[d]
			if i+1 < len(layer) {
				right = layer[i+1]
			}
			next[i/2] = hash2(layer[i], right)
		}
		layer = next
	}
	return layer[0]
}

// uint64Chunk is the SSZ chunk of a uint64: little-endian, zero-padded.
func uint64Chunk(v uint64) []byte {
	c := make([]byte, chunkSize)
	binary.LittleEndian.PutUint64(c, v)
	return c
}

// padChunk right-pads b (at most 32 bytes) to a chunk.
func padChunk(b []byte) []byte {
	if len(b) > chunkSize {
		panic("ssz: value longer than a chunk")
	}
	c := make([]byte, chunkSize)
	copy(c, b)
	return c
}

// pack splits b into chunks, the last one zero-padded.
func pack(b []byte) [][]byte {
	var chunks [][]byte
	for i := 0; i < len(b); i += chunkSize {
		end := i + chunkSize
		if end > len(b) {
			end = len(b)
		}
		chunks = append(chunks, padChunk(b[i:end]))
	}
	return chunks
}

func mixInLength(root []byte, length uint64) []byte {
	return hash2(root, uint64Chunk(length))
}

// HashTreeRoot of BeaconBlockHeader.
func (h BeaconBlockHeader) HashTreeRoot() []byte {
	return merkleize([][]byte{
		uint64Chunk(h.Slot),
		uint64Chunk(h.ProposerIndex),
		h.ParentRoot,
		h.StateRoot,
		h.BodyRoot,
	}, 5)
}

const (
	logsBloomSize   = 256
	maxExtraDataLen = 32
)

// HashTreeRoot of the Deneb-and-later ExecutionPayloadHeader. Electra and
// Fulu did not change this container.
func (h ExecutionPayloadHeader) HashTreeRoot() []byte {
	// base_fee_per_gas is a uint256: little-endian in its chunk.
	baseFee := make([]byte, chunkSize)
	for i := 0; i < len(h.BaseFeePerGas) && i < chunkSize; i++ {
		baseFee[i] = h.BaseFeePerGas[len(h.BaseFeePerGas)-1-i]
	}
	return merkleize([][]byte{
		h.ParentHash,
		padChunk(h.FeeRecipient),
		h.StateRoot,
		h.ReceiptsRoot,
		merkleize(pack(h.LogsBloom), logsBloomSize/chunkSize),
		h.PrevRandao,
		uint64Chunk(h.BlockNumber),
		uint64Chunk(h.GasLimit),
		uint64Chunk(h.GasUsed),
		uint64Chunk(h.Timestamp),
		mixInLength(merkleize(pack(h.ExtraData), (maxExtraDataLen+chunkSize-1)/chunkSize), uint64(len(h.ExtraData))),
		baseFee,
		h.BlockHash,
		h.TransactionsRoot,
		h.WithdrawalsRoot,
		uint64Chunk(h.BlobGasUsed),
		uint64Chunk(h.ExcessBlobGas),
	}, 17)
}

// pubkeyLeaf is the hash_tree_root of a 48-byte BLS public key, its leaf in
// a sync committee's pubkeys vector.
func pubkeyLeaf(pk []byte) []byte {
	return hash2(pk[:chunkSize], padChunk(pk[chunkSize:]))
}

// computeDomain implements compute_domain for the given domain type.
func computeDomain(domainType [4]byte, forkVersion [4]byte, genesisValidatorsRoot []byte) []byte {
	forkDataRoot := hash2(padChunk(forkVersion[:]), genesisValidatorsRoot)
	domain := make([]byte, chunkSize)
	copy(domain, domainType[:])
	copy(domain[4:], forkDataRoot[:28])
	return domain
}

// computeSigningRoot implements compute_signing_root.
func computeSigningRoot(objectRoot, domain []byte) []byte {
	return hash2(objectRoot, domain)
}

// floorLog2 returns floor(log2(n)) for n > 0.
func floorLog2(n uint64) int {
	d := -1
	for n > 0 {
		n >>= 1
		d++
	}
	return d
}

// isValidMerkleBranch implements is_valid_normalized_merkle_branch for a
// generalized index: leaf is at gindex in the tree whose root is root. A
// branch longer than the index's depth must start with zero hashes.
func isValidMerkleBranch(leaf []byte, branch [][]byte, gindex uint64, root []byte) bool {
	depth := floorLog2(gindex)
	if len(branch) < depth {
		return false
	}
	for _, extra := range branch[:len(branch)-depth] {
		if !bytes.Equal(extra, zeroHashes[0]) {
			return false
		}
	}
	branch = branch[len(branch)-depth:]
	index := gindex - (1 << uint(depth))
	value := leaf
	for i := 0; i < depth; i++ {
		if len(branch[i]) != chunkSize {
			return false
		}
		if (index>>uint(i))&1 == 1 {
			value = hash2(branch[i], value)
		} else {
			value = hash2(value, branch[i])
		}
	}
	return bytes.Equal(value, root)
}
