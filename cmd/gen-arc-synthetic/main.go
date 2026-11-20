// Command gen-arc-synthetic writes synthetic Arc light-client test data for
// gno.land/p/aib/ibc/lightclient/arc: the cases the recorded testnet fixture
// cannot give, signed with Ed25519 keys derived from a fixed seed (Gno can
// verify Ed25519 but not sign).
//
// Three blocks of one synthetic Arc chain, each with its full state (the
// ValidatorRegistry proxy, an ICS26 router and filler accounts), from which
// every proof is taken:
//
//   - block 100, where a client is created (Creation): the registry holds
//     the trusted set T;
//   - block 110 (Rotation, certified by block 111): the registry holds a
//     rotated set N, which drops two of T's validators, adds two and
//     changes the others' powers;
//   - block 120 (Reweight, certified by block 121): the registry holds T's
//     validators with changed powers only;
//   - block 130 (Idle, certified by block 131): the registry's storage
//     changed (key 8, active with no power, deactivated) but the set it
//     holds is T;
//   - block 140 (Reorder, certified by block 141): key 0 deactivated and
//     registered again with the same power, so the registry holds T's
//     validators and powers in another order.
//
// Each certificate carries a precommit by every key of the pool, so a test
// picks the signers of a case by filtering them. The router's storage, the
// same in every block, holds two packet commitments; the data has proofs of
// both, and of the absence of a third, in the states of blocks 100 and 110.
//
// Everything the client reads is built from Arc's and Ethereum's own
// definitions, not from the client's code:
//   - blocks are RLP execution headers of the Prague layout Arc's Reth
//     uses, hashed with Keccak-256; a certified block's parent hash names
//     the proven block;
//   - state and storage tries are Merkle-Patricia tries (mpt.go), accounts
//     [nonce, balance, storageRoot, codeHash], storage words RLP-encoded
//     without leading zeros; proofs are eth_getProof's node lists;
//   - the registry's storage is laid out as Solidity lays out its ERC-7201
//     namespace (registry.go): the registrations mapping, the
//     EnumerableSet of active registrations (values and positions), the
//     next registration id, and the proxy's ERC-1967 implementation slot;
//   - a precommit signs the SSZ encoding of arc-node's Vote without its
//     extension (signBytes), and a validator's address is the first 20
//     bytes of the Keccak-256 of its key;
//   - a commitment of the router is commitments[keccak256(path)] in the
//     mapping at its commitment slot;
//   - messages use the client's wire format (wire.go).
//
// Arbitrary, derived from the seed: the parents of the proven blocks, the
// filler accounts and router slots, code hashes, commitment values, the
// coinbase and the registry's implementation address. The other header
// fields are set as in the testnet's blocks: no transactions, withdrawals
// or requests (their empty roots), a zero bloom, mix digest and nonce, the
// base fee in the extra data, the parent beacon root equal to the parent
// hash.
//
// Regenerate from the repository root with
//
//	go run -C cmd/gen-arc-synthetic . ../../gno.land/p/aib/ibc/lightclient/arc/v0/zz_synthetic_test.gno
//
// and `go test -C cmd/gen-arc-synthetic` checks that the committed file is
// what the generator writes.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"go/format"
	"os"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: gen-arc-synthetic <out.gno>")
		os.Exit(2)
	}
	out, err := generate()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := os.WriteFile(os.Args[1], out, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

const (
	seed           = "gno-realms synthetic arc light-client fixtures v1"
	chainID        = 7777
	trustingPeriod = 24 * 3600
	maxClockDrift  = 90
	genesisTime    = 1800000000
	creationHeight = 100
	rotationHeight = 110
	reweightHeight = 120
	idleHeight     = 130
	reorderHeight  = 140
	rotationRound  = 1
	reweightRound  = 0
	idleRound      = 0
	reorderRound   = 0
	keyCount       = 9 // keys 0..7 sign; key 8 is registered without power
	signingKeys    = 8
	fillerAccounts = 24
	fillerSlots    = 24
	clientID       = "client-0"
)

var (
	registryAddress  = mustHex("3600000000000000000000000000000000000002")
	registryLocation = mustHex("b58da0dce03316992faea3e12c60705b8ac05a309e27e3bc8421e5b271c9d200")
	routerAddress    = mustHex("1d95d544586eacb63b6154e9e45122b32ded11aa")
	commitmentSlot   = mustHex("1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600")
	trustLevel       = [2]uint64{1, 3}
)

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func h32(parts ...string) []byte {
	h := sha256.New()
	h.Write([]byte(seed))
	for _, p := range parts {
		h.Write([]byte{0})
		h.Write([]byte(p))
	}
	return h.Sum(nil)
}

// keys are the validators' Ed25519 keys, from the seed.
var keys = func() []ed25519.PrivateKey {
	out := make([]ed25519.PrivateKey, keyCount)
	for i := range out {
		out[i] = ed25519.NewKeyFromSeed(h32("validator", fmt.Sprint(i)))
	}
	return out
}()

func pubKey(i int) []byte { return keys[i].Public().(ed25519.PublicKey) }

// arcAddress is a validator's address: the first 20 bytes of the
// Keccak-256 of its public key (arc-node crates/types/src/address.rs).
func arcAddress(pub []byte) []byte { return keccak(pub)[:20] }

// signBytes is the SSZ encoding of arc-node's Vote without its extension
// (crates/types/src/vote.rs, to_sign_bytes), what a precommit signs: the
// container {type: uint8, height: uint64, round: Option<u32>, value:
// NilOrVal<BlockHash>, address: [20]byte}, laid out as SSZ lays out a
// container, fixed-size fields in place and the two variable-size unions by
// an offset into the tail; a union is its selector then its value.
func signBytes(height uint64, round uint32, blockHash, address []byte) []byte {
	const precommit = 1
	roundUnion := binary.LittleEndian.AppendUint32([]byte{1}, round) // Some(round)
	valueUnion := append([]byte{1}, blockHash...)                    // Val(hash)
	fixed := 1 + 8 + 4 + 4 + len(address)
	b := []byte{precommit}
	b = binary.LittleEndian.AppendUint64(b, height)
	b = binary.LittleEndian.AppendUint32(b, uint32(fixed))
	b = binary.LittleEndian.AppendUint32(b, uint32(fixed+len(roundUnion)))
	b = append(b, address...)
	b = append(b, roundUnion...)
	return append(b, valueUnion...)
}

// member is a validator of a set: a key and its power.
type member struct {
	key   int
	power uint64
}

// The sets. T is created with; N, the rotation, drops keys 4 and 5, adds 6
// and 7, and changes every kept power; the reweight keeps T's keys with
// other powers. Key 8 stays registered and active with no power, which the
// consensus layer (and the client) skips.
var (
	trustedSet  = []member{{0, 4}, {1, 1}, {2, 1}, {3, 1}, {4, 1}, {5, 1}}
	rotatedPows = map[int]uint64{0: 1, 1: 3, 2: 3, 3: 3, 6: 3, 7: 2}
	reweighted  = map[int]uint64{0: 1, 1: 7}
)

// block is an execution block and the state it commits to.
type block struct {
	header executionHeader
	rlp    []byte
	hash   []byte
	state  *secureTrie
	reg    *registry
	router storage
}

func newHeader(number uint64, parent, stateRoot []byte) executionHeader {
	emptyTrie := emptyTrieRoot()
	const baseFee = 20_000_000_000
	extra := binary.BigEndian.AppendUint64(nil, baseFee)
	return executionHeader{
		ParentHash: parent, OmmersHash: keccak(rlpList()), Coinbase: h32("coinbase")[:20], StateRoot: stateRoot,
		TxRoot: emptyTrie, ReceiptsRoot: emptyTrie, Bloom: make([]byte, 256),
		Number: number, GasLimit: 30_000_000, GasUsed: 0, Time: genesisTime + (number-creationHeight)/2,
		Extra: extra, MixDigest: make([]byte, 32), Nonce: make([]byte, 8),
		BaseFee: baseFee, WithdrawalsRoot: emptyTrie, ParentBeaconRoot: parent,
		RequestsHash: func() []byte { s := sha256.Sum256(nil); return s[:] }(), // EIP-7685: no requests
	}
}

func sealed(h executionHeader) (rlp, hash []byte) {
	rlp = h.rlp()
	return rlp, keccak(rlp)
}

// routerStorage is the router's storage: the commitments of packets 1 and 2
// and filler slots.
func routerStorage() storage {
	s := newStorage()
	for i := 0; i < fillerSlots; i++ {
		s.setWord(h32("router slot", fmt.Sprint(i)), h32("router word", fmt.Sprint(i)))
	}
	for _, seq := range []uint64{1, 2} {
		s.setWord(commitmentKey(packetPath(seq)), commitmentValue(seq))
	}
	return s
}

// packetPath is the router's packet commitment path: the client id, 0x01,
// the big-endian sequence.
func packetPath(seq uint64) []byte {
	return binary.BigEndian.AppendUint64(append([]byte(clientID), 1), seq)
}

func commitmentValue(seq uint64) []byte { return h32("commitment", fmt.Sprint(seq)) }

// commitmentKey is the slot of commitments[keccak256(path)]: a mapping
// entry, keccak256(abi.encode(key, mappingSlot)).
func commitmentKey(path []byte) []byte {
	return keccak(append(keccak(path), commitmentSlot...))
}

func newBlock(number uint64, reg *registry) block {
	b := block{reg: reg, router: routerStorage(), state: newSecureTrie()}
	emptyCode := keccak(nil)
	for i := 0; i < fillerAccounts; i++ {
		b.state.set(h32("account", fmt.Sprint(i))[:20], account(uint64(i), 1_000_000+uint64(i), emptyTrieRoot(), emptyCode))
	}
	b.state.set(registryAddress, account(1, 0, reg.storage().hash(), h32("registry proxy code")))
	b.state.set(routerAddress, account(1, 0, b.router.hash(), h32("router code")))
	b.header = newHeader(number, h32("parent", fmt.Sprint(number)), b.state.hash())
	b.rlp, b.hash = sealed(b.header)
	return b
}

func emptyTrieRoot() []byte { return keccak(rlpBytes(nil)) }

// child is the block after b, which certifies it.
func (b block) child() (rlp, hash []byte) {
	h := newHeader(b.header.Number+1, b.hash, h32("child state", fmt.Sprint(b.header.Number)))
	return sealed(h)
}

// registryProofs are the registry's account proof in b's state and the pool
// of every node of its storage proofs, each node once.
func (b block) registryProofs() (accountProof, nodes [][]byte) {
	st := b.reg.storage()
	seen := map[string]bool{}
	for _, slot := range st.slots() {
		for _, n := range st.prove(slot) {
			if !seen[string(n)] {
				seen[string(n)] = true
				nodes = append(nodes, n)
			}
		}
	}
	return b.state.prove(registryAddress), nodes
}

// certificate signs the child of b with every key of 0..7.
func (b block) certificate(round uint32) (certified, hash []byte, sigs [][2][]byte) {
	certified, hash = b.child()
	for i := 0; i < signingKeys; i++ {
		addr := arcAddress(pubKey(i))
		msg := signBytes(b.header.Number+1, round, hash, addr)
		sig := ed25519.Sign(keys[i], msg)
		if !ed25519.Verify(pubKey(i), msg, sig) {
			panic("signature")
		}
		sigs = append(sigs, [2][]byte{addr, sig})
	}
	return certified, hash, sigs
}

func (b block) headerMessage(trusted uint64, round uint32) []byte {
	certified, hash, sigs := b.certificate(round)
	accountProof, nodes := b.registryProofs()
	w := &wireWriter{}
	w.uint(trusted).uint(b.header.Number + 1).uint(uint64(round)).blob(hash)
	w.uvarint(uint64(len(sigs)))
	for _, s := range sigs {
		w.blob(s[0]).blob(s[1])
	}
	w.blob(certified).blob(b.rlp).blobs(accountProof).blobs(nodes)
	return w.buf
}

func (b block) creationMessage() []byte {
	accountProof, nodes := b.registryProofs()
	w := &wireWriter{}
	w.uint(chainID).uint(trustingPeriod).uint(maxClockDrift).uint(trustLevel[0]).uint(trustLevel[1])
	w.blob(registryAddress).blob(registryLocation).blob(routerAddress).blob(commitmentSlot)
	w.blob(b.rlp).blobs(accountProof).blobs(nodes)
	return w.buf
}

// commitmentProof is eth_getProof's proof of the router's commitment at
// path in b's state.
func (b block) commitmentProof(path []byte) (accountProof, storageProof [][]byte) {
	return b.state.prove(routerAddress), b.router.prove(commitmentKey(path))
}

type chain struct {
	creation, rotation, reweight, idle, reorder    block
	trusted, rotated, reweighted, idled, reordered []member
}

func newChain() chain {
	reg := newRegistry(h32("registry implementation")[:20])
	for _, m := range trustedSet {
		reg.register(pubKey(m.key), m.power)
	}
	reg.register(pubKey(8), 0)
	var c chain
	c.creation = newBlock(creationHeight, reg.clone())
	c.trusted = reg.members()

	rot := reg.clone()
	rot.deactivate(pubKey(4))
	rot.deactivate(pubKey(5))
	rot.register(pubKey(6), rotatedPows[6])
	rot.register(pubKey(7), rotatedPows[7])
	for k := 0; k < 4; k++ {
		rot.setPower(pubKey(k), rotatedPows[k])
	}
	c.rotation = newBlock(rotationHeight, rot)
	c.rotated = rot.members()

	rew := reg.clone()
	for k, p := range reweighted {
		rew.setPower(pubKey(k), p)
	}
	c.reweight = newBlock(reweightHeight, rew)
	c.reweighted = rew.members()

	idle := reg.clone()
	idle.deactivate(pubKey(8))
	c.idle = newBlock(idleHeight, idle)
	c.idled = idle.members()

	re := reg.clone()
	re.deactivate(pubKey(0))
	re.register(pubKey(0), trustedSet[0].power)
	c.reorder = newBlock(reorderHeight, re)
	c.reordered = re.members()
	return c
}

// --- Gno output ---

type writer struct{ bytes.Buffer }

func (w *writer) f(format string, args ...any) { fmt.Fprintf(&w.Buffer, format, args...) }

func hx(b []byte) string { return fmt.Sprintf("h(%q)", hex.EncodeToString(b)) }

func blobs(bs [][]byte) string {
	s := "[][]byte{"
	for _, b := range bs {
		s += hx(b) + ", "
	}
	return s + "}"
}

func (w *writer) members(name, doc string, ms []member) {
	w.f("\n// %s\nvar %s = []syntheticMember{", doc, name)
	for _, m := range ms {
		w.f("{%d, %d}, ", m.key, m.power)
	}
	w.f("}\n")
}

func generate() ([]byte, error) {
	c := newChain()
	var w writer
	w.f("// Code generated by cmd/gen-arc-synthetic. DO NOT EDIT.\n\n")
	w.f("// Synthetic Arc light-client data, signed by Ed25519 keys derived from a fixed\n")
	w.f("// seed: the cases the testnet fixture cannot give. See cmd/gen-arc-synthetic\n")
	w.f("// for how each is built.\n\npackage arc\n\nimport \"gno.land/p/aib/ibc/lightclient/ethereum/v0\"\n\n")
	w.f("const (\n")
	w.f("// syntheticCreationHeight, syntheticRotationHeight, syntheticReweightHeight,\n// syntheticIdleHeight and syntheticReorderHeight are the blocks of Creation,\n// Rotation, Reweight, Idle and Reorder.\n")
	w.f("syntheticCreationHeight = %d\nsyntheticRotationHeight = %d\nsyntheticReweightHeight = %d\nsyntheticIdleHeight = %d\nsyntheticReorderHeight = %d\n", creationHeight, rotationHeight, reweightHeight, idleHeight, reorderHeight)
	w.f("// syntheticTime is a clock at which every synthetic block is past and the\n// client not expired.\nsyntheticTime = %d\n)\n", genesisTime+60)

	w.f("\n// syntheticCreation creates a client (chain %d, trust level %d/%d, trusting\n// period %d s, drift %d s) at block %d, whose registry holds syntheticTrusted.\nvar syntheticCreation = %s\n",
		chainID, trustLevel[0], trustLevel[1], trustingPeriod, maxClockDrift, creationHeight, hx(c.creation.creationMessage()))
	w.f("\n// syntheticRotation updates from block %d to block %d, whose registry holds\n// syntheticRotated, with the certificate of block %d (round %d): a precommit by\n// every key 0 to 7, in key order.\nvar syntheticRotation = %s\n",
		creationHeight, rotationHeight, rotationHeight+1, rotationRound, hx(c.rotation.headerMessage(creationHeight, rotationRound)))
	w.f("\n// syntheticReweight updates from block %d to block %d, whose registry holds\n// syntheticReweighted, with the certificate of block %d (round %d): a precommit\n// by every key 0 to 7, in key order.\nvar syntheticReweight = %s\n",
		creationHeight, reweightHeight, reweightHeight+1, reweightRound, hx(c.reweight.headerMessage(creationHeight, reweightRound)))
	w.f("\n// syntheticIdle updates from block %d to block %d, whose registry's storage\n// changed but holds syntheticTrusted (syntheticIdled), with the certificate of\n// block %d (round %d): a precommit by every key 0 to 7, in key order.\nvar syntheticIdle = %s\n",
		creationHeight, idleHeight, idleHeight+1, idleRound, hx(c.idle.headerMessage(creationHeight, idleRound)))
	w.f("\n// syntheticReorder updates from block %d to block %d, whose registry holds\n// syntheticTrusted's validators and powers in another order\n// (syntheticReordered), with the certificate of block %d (round %d): a\n// precommit by every key 0 to 7, in key order.\nvar syntheticReorder = %s\n",
		creationHeight, reorderHeight, reorderHeight+1, reorderRound, hx(c.reorder.headerMessage(creationHeight, reorderRound)))

	w.f("\n// syntheticPubKeys are the validators' Ed25519 public keys, by key index.\nvar syntheticPubKeys = [][]byte{\n")
	for i := 0; i < keyCount; i++ {
		w.f("%s,\n", hx(pubKey(i)))
	}
	w.f("}\n")
	w.members("syntheticTrusted", "syntheticTrusted is the set block 100's registry holds, in registry order.", c.trusted)
	w.members("syntheticRotated", "syntheticRotated is the set block 110's registry holds: keys 4 and 5\n// deactivated, 6 and 7 registered, every kept power changed.", c.rotated)
	w.members("syntheticReweighted", "syntheticReweighted is the set block 120's registry holds: syntheticTrusted's\n// keys, keys 0 and 1 with other powers.", c.reweighted)
	w.members("syntheticIdled", "syntheticIdled is the set block 130's registry holds: syntheticTrusted, under\n// another storage root.", c.idled)
	w.members("syntheticReordered", "syntheticReordered is the set block 140's registry holds: syntheticTrusted's\n// validators and powers, key 0 moved last.", c.reordered)

	w.f("\n// syntheticCommitments are proofs of the router's commitments at %q 0x01\n// sequence, in the states of blocks %d and %d: of sequences 1 and 2, stored,\n// and of the absence of sequence 3 (Value nil).\nvar syntheticCommitments = []syntheticCommitment{\n",
		clientID, creationHeight, rotationHeight)
	for _, b := range []block{c.creation, c.rotation} {
		for _, seq := range []uint64{1, 2, 3} {
			path := packetPath(seq)
			value := "nil"
			if seq != 3 {
				value = hx(commitmentValue(seq))
			}
			ap, sp := b.commitmentProof(path)
			w.f("{Height: %d, Sequence: %d, Path: %s, Value: %s, Proof: ethereum.MembershipProof{AccountProof: %s, StorageProof: %s}},\n",
				b.header.Number, seq, hx(path), value, blobs(ap), blobs(sp))
		}
	}
	w.f("}\n")
	return format.Source(w.Bytes())
}
