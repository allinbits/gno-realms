package ethereum

import (
	"crypto/keccak256"
	"encoding/hex"
	"errors"
)

// Merkle-Patricia trie proof verification, as produced by eth_getProof.
// See https://ethereum.org/developers/docs/data-structures-and-encoding/patricia-merkle-trie

var errMissingProofNode = errors.New("mpt: proof is missing a node")

func keccak(b []byte) []byte {
	h := keccak256.Sum256(b)
	return h[:]
}

// mptGet returns the value stored under keccak256(key) in the trie with the
// given root, using proof (the list of RLP-encoded nodes on the path). found
// is false when the proof shows that no value is stored there. An error
// means the proof does not establish either.
func mptGet(root, key []byte, proof [][]byte) (value []byte, found bool, err error) {
	nodes := make(map[string][]byte, len(proof))
	for _, n := range proof {
		nodes[hex.EncodeToString(keccak(n))] = n
	}
	path := toNibbles(keccak(key))

	node, ok := nodes[hex.EncodeToString(root)]
	if !ok {
		return nil, false, errMissingProofNode
	}
	for {
		item, err := rlpDecode(node)
		if err != nil {
			return nil, false, err
		}
		elems, err := rlpList(item)
		if err != nil {
			return nil, false, err
		}

		var child rlpItem
		switch len(elems) {
		case 17: // branch
			if len(path) == 0 {
				v := elems[16]
				if v.isList {
					return nil, false, errRLP
				}
				return v.payload, len(v.payload) > 0, nil
			}
			child = elems[path[0]]
			path = path[1:]
		case 2: // extension or leaf
			if elems[0].isList {
				return nil, false, errRLP
			}
			nodePath, isLeaf, err := decodeCompactPath(elems[0].payload)
			if err != nil {
				return nil, false, err
			}
			if isLeaf {
				if !nibblesEqual(nodePath, path) {
					return nil, false, nil // diverges: absent
				}
				if elems[1].isList {
					return nil, false, errRLP
				}
				return elems[1].payload, true, nil
			}
			if len(path) < len(nodePath) || !nibblesEqual(nodePath, path[:len(nodePath)]) {
				return nil, false, nil // diverges: absent
			}
			path = path[len(nodePath):]
			child = elems[1]
		default:
			return nil, false, errRLP
		}

		// Resolve the child reference: empty means absent, a list is an
		// embedded node (encoded in under 32 bytes), 32 bytes is a hash.
		switch {
		case child.isList:
			node = child.raw
		case len(child.payload) == 0:
			return nil, false, nil
		case len(child.payload) == 32:
			node, ok = nodes[hex.EncodeToString(child.payload)]
			if !ok {
				return nil, false, errMissingProofNode
			}
		default:
			return nil, false, errRLP
		}
	}
}

func toNibbles(b []byte) []byte {
	n := make([]byte, 2*len(b))
	for i, c := range b {
		n[2*i] = c >> 4
		n[2*i+1] = c & 0x0f
	}
	return n
}

// decodeCompactPath decodes a hex-prefix encoded node path.
func decodeCompactPath(b []byte) (nibbles []byte, isLeaf bool, err error) {
	if len(b) == 0 {
		return nil, false, errRLP
	}
	flag := b[0] >> 4
	if flag > 3 {
		return nil, false, errRLP
	}
	isLeaf = flag >= 2
	all := toNibbles(b)
	if flag%2 == 1 { // odd: the first nibble is part of the path
		return all[1:], isLeaf, nil
	}
	if b[0]&0x0f != 0 {
		return nil, false, errRLP
	}
	return all[2:], isLeaf, nil
}

func nibblesEqual(a, b []byte) bool {
	return bytesEqual(a, b)
}

// verifyAccountStorageRoot returns the storage root of the account at
// address in the state trie with root stateRoot.
func accountStorageRoot(stateRoot, address []byte, proof [][]byte) ([]byte, error) {
	v, found, err := mptGet(stateRoot, address, proof)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, errors.New("mpt: account not found")
	}
	item, err := rlpDecode(v)
	if err != nil {
		return nil, err
	}
	fields, err := rlpList(item)
	if err != nil {
		return nil, err
	}
	// [nonce, balance, storageRoot, codeHash]
	if len(fields) != 4 || fields[2].isList || len(fields[2].payload) != 32 {
		return nil, errRLP
	}
	return fields[2].payload, nil
}

// storageValue returns the 32-byte value of slot key in the storage trie with
// the given root, zero when the proof shows it is unset.
func storageValue(storageRoot, key []byte, proof [][]byte) ([]byte, error) {
	v, found, err := mptGet(storageRoot, key, proof)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 32)
	if !found {
		return out, nil
	}
	// The leaf holds rlp(value) with leading zero bytes stripped.
	item, err := rlpDecode(v)
	if err != nil {
		return nil, err
	}
	if item.isList || len(item.payload) > 32 || len(item.payload) == 0 || item.payload[0] == 0 {
		return nil, errRLP
	}
	copy(out[32-len(item.payload):], item.payload)
	return out, nil
}
