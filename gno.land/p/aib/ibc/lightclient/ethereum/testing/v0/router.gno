package testing

import (
	"crypto/keccak256"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
)

// Router is a fake Ethereum state holding the ICS26 router's commitments, so
// a filetest can relay real packets, acknowledgements and timeouts over an
// Ethereum client: Commit stores values as the router would, StateRoot is the
// execution state root that commits to them, and Proof the MembershipProof
// the client verifies against a consensus state carrying that root
// (ConsensusStateWithRoot). It builds genuine Merkle-Patricia tries, one
// storage trie for the router and a state trie with its account alone, so
// the client verifies them exactly as it verifies eth_getProof output.
type Router struct {
	slots map[string][]byte // storage slot -> 32-byte value
}

// NewRouter is a router with no commitment.
func NewRouter() *Router { return &Router{slots: map[string][]byte{}} }

// Commit stores value under the commitment path key (an ICS24 key: the
// counterparty's empty merkle prefix leaves it as is), as the router's
// commitments[keccak256(key)] at the fixture's mapping slot.
func (r *Router) Commit(key, value []byte) {
	if len(value) != 32 {
		panic("a commitment is 32 bytes")
	}
	slot := keccak(append(keccak(key), ClientState().IBCCommitmentSlot...))
	r.slots[string(slot)] = append([]byte{}, value...)
}

// CommitPacket stores the commitment of a packet sent by the router.
func (r *Router) CommitPacket(p types.Packet) {
	r.Commit(host.PacketCommitmentKey(p.SourceClient, p.Sequence), types.CommitPacket(p))
}

// CommitAcknowledgement stores the acknowledgement the router wrote for a
// packet it received.
func (r *Router) CommitAcknowledgement(p types.Packet, ack types.Acknowledgement) {
	r.Commit(host.PacketAcknowledgementKey(p.DestinationClient, p.Sequence), types.CommitAcknowledgement(ack))
}

// CommitReceipt stores the receipt the router writes when it receives a
// packet: keccak256(abi.encode(packet)) at its ICS24 receipt path.
func (r *Router) CommitReceipt(p types.Packet) {
	r.Commit(host.PacketReceiptKey(p.DestinationClient, p.Sequence), ethereum.PacketReceiptCommitment(p))
}

// StateRoot is the state root committing to every value stored so far.
func (r *Router) StateRoot() []byte {
	root, _ := r.tries()
	return root
}

// Proof proves every value stored so far (and the absence of any other)
// against StateRoot: the proof lists every node of both tries.
func (r *Router) Proof() ethereum.MembershipProof {
	_, p := r.tries()
	return p
}

func (r *Router) tries() ([]byte, ethereum.MembershipProof) {
	var storage []leaf
	for slot, v := range r.slots {
		storage = append(storage, leaf{path: nibbles(keccak([]byte(slot))), value: rlpString(rlpString(trimZeros(v)))})
	}
	var storageNodes [][]byte
	storageRoot := trieRoot(storage, &storageNodes)
	account := rlpList(rlpString(nil), rlpString(nil), rlpString(storageRoot), rlpString(keccak(nil)))
	var accountNodes [][]byte
	stateRoot := trieRoot([]leaf{{path: nibbles(keccak(ClientState().IBCContractAddress)), value: rlpString(account)}}, &accountNodes)
	return stateRoot, ethereum.MembershipProof{AccountProof: accountNodes, StorageProof: storageNodes}
}

// ConsensusStateWithRoot is ConsensusState with the execution state root set
// to root.
func ConsensusStateWithRoot(root []byte) ethereum.ConsensusState {
	cs := ConsensusState()
	cs.StateRoot = append([]byte{}, root...)
	return cs
}

// ---------------------------------------------------------------- the trie

type leaf struct {
	path  []byte // nibbles
	value []byte // the leaf's value item: rlp(the RLP the trie stores)
}

// emptyRoot is the root of an empty trie, keccak256(rlp("")).
var emptyRoot = keccak([]byte{0x80})

// trieRoot builds the trie of leaves (distinct 64-nibble paths), appends every
// node to nodes and returns its root hash. Every node here is at least 32
// bytes (a leaf holds a 32-byte remainder or value), so each is referenced by
// its hash.
func trieRoot(leaves []leaf, nodes *[][]byte) []byte {
	if len(leaves) == 0 {
		return emptyRoot
	}
	return keccak(node(leaves, nodes))
}

func node(leaves []leaf, nodes *[][]byte) []byte {
	var enc []byte
	if len(leaves) == 1 {
		enc = rlpList(rlpString(hexPrefix(leaves[0].path, true)), leaves[0].value)
	} else if n := commonPrefix(leaves); n > 0 {
		rest := make([]leaf, len(leaves))
		for i, l := range leaves {
			rest[i] = leaf{path: l.path[n:], value: l.value}
		}
		child := keccak(node(rest, nodes))
		enc = rlpList(rlpString(hexPrefix(leaves[0].path[:n], false)), rlpString(child))
	} else {
		items := make([][]byte, 17)
		for nib := byte(0); nib < 16; nib++ {
			var group []leaf
			for _, l := range leaves {
				if l.path[0] == nib {
					group = append(group, leaf{path: l.path[1:], value: l.value})
				}
			}
			if len(group) == 0 {
				items[nib] = rlpString(nil)
				continue
			}
			items[nib] = rlpString(keccak(node(group, nodes)))
		}
		items[16] = rlpString(nil)
		enc = rlpList(items...)
	}
	*nodes = append(*nodes, enc)
	return enc
}

func commonPrefix(leaves []leaf) int {
	n := len(leaves[0].path)
	for _, l := range leaves[1:] {
		i := 0
		for i < n && i < len(l.path) && l.path[i] == leaves[0].path[i] {
			i++
		}
		n = i
	}
	return n
}

// hexPrefix is the compact encoding of a nibble path.
func hexPrefix(path []byte, isLeaf bool) []byte {
	flag := byte(0)
	if isLeaf {
		flag = 2
	}
	var out []byte
	rest := path
	if len(path)%2 == 1 {
		out = append(out, (flag+1)<<4|path[0])
		rest = path[1:]
	} else {
		out = append(out, flag<<4)
	}
	for i := 0; i < len(rest); i += 2 {
		out = append(out, rest[i]<<4|rest[i+1])
	}
	return out
}

func nibbles(b []byte) []byte {
	out := make([]byte, 2*len(b))
	for i, c := range b {
		out[2*i], out[2*i+1] = c>>4, c&0x0f
	}
	return out
}

func trimZeros(b []byte) []byte {
	for len(b) > 0 && b[0] == 0 {
		b = b[1:]
	}
	return b
}

func keccak(b []byte) []byte {
	h := keccak256.Sum256(b)
	return h[:]
}

// ------------------------------------------------------------------ RLP

func rlpLength(n int, short byte) []byte {
	if n < 56 {
		return []byte{short + byte(n)}
	}
	var lb []byte
	for x := n; x > 0; x >>= 8 {
		lb = append([]byte{byte(x)}, lb...)
	}
	return append([]byte{short + 55 + byte(len(lb))}, lb...)
}

func rlpString(b []byte) []byte {
	if len(b) == 1 && b[0] < 0x80 {
		return []byte{b[0]}
	}
	return append(rlpLength(len(b), 0x80), b...)
}

func rlpList(items ...[]byte) []byte {
	var payload []byte
	for _, it := range items {
		payload = append(payload, it...)
	}
	return append(rlpLength(len(payload), 0xc0), payload...)
}
