// Command gen-eth-synthetic writes synthetic, spec-exact Ethereum
// light-client test data for gno.land/p/aib/ibc/lightclient/ethereum: the
// cases recorded chains cannot give, signed by a sync committee whose BLS keys
// it derives from a fixed seed.
//
//   - an update attested in Gloas whose finalized header is still Fulu, signed
//     under the Gloas domain;
//   - the same with the finalized header in Gloas' block-hash form (gindex
//     812) and its full RLP execution header;
//   - two valid updates finalizing different headers at one slot
//     (conflicting-finality misbehaviour);
//   - an update with several non-signers, and a signature by a key outside
//     the committee.
//
// It is written from the consensus specs (ssz, phase0/altair beacon-chain,
// the altair to gloas light-client sync protocols) and the execution block
// header layout, not from the gno client: SSZ roots, domains and signing
// roots are computed here, and signatures come from blst, while the native
// the client verifies with wraps gnark-crypto. Branches whose siblings only
// need to be consistent come from sparse trees with arbitrary filler nodes.
//
// Regenerate from the repository root with
//
//	go run -C cmd/gen-eth-synthetic . ../../gno.land/p/aib/ibc/lightclient/ethereum/v0/zz_synthetic_test.gno
//
// and `go test -C cmd/gen-eth-synthetic` checks that the committed file is
// what the generator writes.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"go/format"
	"os"

	blst "github.com/supranational/blst/bindings/go"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: gen-eth-synthetic <out.gno>")
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

// The chain: 2 s slots, 8-slot epochs, 8-epoch (64-slot) periods; every fork
// to Electra at genesis, Fulu at epoch 1, Gloas at epoch 18 (slot 144).
const (
	seed            = "gno-realms synthetic ethereum light-client fixtures v1"
	committeeSize   = 32
	minParticipants = 11
	genesisTime     = 1700000000
	secondsPerSlot  = 2
	slotsPerEpoch   = 8
	epochsPerPeriod = 8
	gloasEpoch      = 18
	trustedSlot     = 128 // period 2
	finalizedSlot   = 136 // epoch 17: Fulu
	attestedSlot    = 144 // epoch 18: Gloas
	signatureSlot   = 145 // signature_slot - 1 = 144: the Gloas domain
	router          = "1d95d544586eacb63b6154e9e45122b32ded11aa"
	commitmentSlot  = "1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600"

	// Generalized indices (electra and gloas light-client sync protocols).
	finalizedRootGloas        = 735
	nextSyncCommitteeGloas    = 2946
	executionBlockHashGloas   = 2856
	executionPayloadIndex     = 25
	executionBlockHashDeneb   = 812
	executionBranchDepthGloas = 11 // floorlog2(EXECUTION_BLOCK_HASH_GINDEX_GLOAS)
)

var (
	dst                 = []byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
	domainSyncCommittee = [4]byte{0x07, 0, 0, 0}
	gvr                 = sha([]byte(seed), []byte("genesis validators root"))
)

type fork struct {
	name    string
	version [4]byte
	epoch   uint64
}

func v(b byte) [4]byte { return [4]byte{b, 0, 0, 0x99} }

var (
	genesisVersion = v(0x10)
	forks          = []fork{
		{"Altair", v(0x20), 0}, {"Bellatrix", v(0x30), 0}, {"Capella", v(0x40), 0},
		{"Deneb", v(0x50), 0}, {"Electra", v(0x60), 0}, {"Fulu", v(0x70), 1},
		{"Gloas", v(0x80), gloasEpoch},
	}
)

// computeForkVersion implements compute_fork_version (gloas p2p-interface).
func computeForkVersion(epoch uint64) [4]byte {
	for i := len(forks) - 1; i >= 0; i-- {
		if epoch >= forks[i].epoch {
			return forks[i].version
		}
	}
	return genesisVersion
}

// committee is a sync committee of keys derived from seed and name.
type committee struct {
	sks       []*blst.SecretKey
	pks       [][]byte
	aggregate []byte
}

func newCommittee(name string) committee {
	var c committee
	var affs []*blst.P1Affine
	for i := 0; i < committeeSize; i++ {
		ikm := sha([]byte(seed), []byte(name), uint64Leaf(uint64(i)))
		sk := blst.KeyGen(ikm)
		pk := new(blst.P1Affine).From(sk)
		c.sks = append(c.sks, sk)
		c.pks = append(c.pks, pk.Compress())
		affs = append(affs, pk)
	}
	agg := new(blst.P1Aggregate)
	if !agg.Aggregate(affs, false) {
		panic("aggregate keys")
	}
	c.aggregate = agg.ToAffine().Compress()
	return c
}

func (c committee) root() []byte { return syncCommitteeRoot(c.pks, c.aggregate) }

func outsider() *blst.SecretKey {
	return blst.KeyGen(sha([]byte(seed), []byte("outsider")))
}

// sign aggregates the signatures of every member not in nonSigners over msg,
// with keys[i] signing for member i when set.
func (c committee) sign(msg []byte, nonSigners map[int]bool, keys map[int]*blst.SecretKey) []byte {
	var sigs []*blst.P2Affine
	var pks []*blst.P1Affine
	for i, sk := range c.sks {
		if nonSigners[i] {
			continue
		}
		if k, ok := keys[i]; ok {
			sk = k
		}
		sigs = append(sigs, new(blst.P2Affine).Sign(sk, msg, dst))
		pks = append(pks, new(blst.P1Affine).From(sk))
	}
	agg := new(blst.P2Aggregate)
	if !agg.Aggregate(sigs, false) {
		panic("aggregate signatures")
	}
	sig := agg.ToAffine()
	if !sig.FastAggregateVerify(true, pks, msg, dst) {
		panic("blst does not verify its own aggregate")
	}
	return sig.Compress()
}

func bits(nonSigners map[int]bool) []byte {
	out := make([]byte, committeeSize/8)
	for i := 0; i < committeeSize; i++ {
		if !nonSigners[i] {
			out[i/8] |= 1 << uint(i%8)
		}
	}
	return out
}

func h32(parts ...string) []byte {
	var bs [][]byte
	for _, p := range parts {
		bs = append(bs, []byte(p))
	}
	return sha(append([][]byte{[]byte(seed)}, bs...)...)
}

// The execution block the finalized header commits to, in both forms: its
// RLP header (hashing to the block hash) and its payload header.
type execBlock struct {
	header  executionHeader
	rlp     []byte
	hash    []byte
	payload payloadHeader
}

func newExecBlock(tag string, number, time uint64) execBlock {
	bloom := make([]byte, 256)
	bloom[7] = 1
	eh := executionHeader{
		ParentHash:   h32(tag, "parent"),
		OmmersHash:   mustHex("1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"), // keccak(rlp([]))
		Coinbase:     h32(tag, "coinbase")[:20],
		StateRoot:    h32(tag, "state root"),
		TxRoot:       h32(tag, "transactions"),
		ReceiptsRoot: h32(tag, "receipts"),
		Bloom:        bloom,
		Number:       number, GasLimit: 30_000_000, GasUsed: 1_234_567, Time: time,
		Extra:            []byte("synthetic"),
		MixDigest:        h32(tag, "prev randao"),
		Nonce:            make([]byte, 8),
		BaseFee:          7,
		WithdrawalsRoot:  h32(tag, "withdrawals"),
		BlobGasUsed:      131072,
		ExcessBlobGas:    0,
		ParentBeaconRoot: h32(tag, "parent beacon root"),
		RequestsHash:     h32(tag, "requests"),
	}
	b := execBlock{header: eh, rlp: eh.rlp()}
	b.hash = keccak(b.rlp)
	b.payload = payloadHeader{
		ParentHash: eh.ParentHash, FeeRecipient: eh.Coinbase, StateRoot: eh.StateRoot,
		ReceiptsRoot: eh.ReceiptsRoot, LogsBloom: eh.Bloom, PrevRandao: eh.MixDigest,
		BlockNumber: eh.Number, GasLimit: eh.GasLimit, GasUsed: eh.GasUsed, Timestamp: eh.Time,
		ExtraData: eh.Extra, BaseFeePerGas: eh.BaseFee, BlockHash: b.hash,
		TransactionsRoot: h32(tag, "transactions ssz root"), WithdrawalsRoot: h32(tag, "withdrawals ssz root"),
		BlobGasUsed: eh.BlobGasUsed, ExcessBlobGas: eh.ExcessBlobGas,
	}
	return b
}

// lcHeader is a light-client header: a beacon header and its execution data.
type lcHeader struct {
	beacon    beaconHeader
	payload   *payloadHeader // payload form
	blockHash []byte         // block-hash form
	branch    [][]byte
}

// finalizedHeader builds the Fulu finalized header for block, in the
// payload form (gindex 25) or Gloas' block-hash form (gindex 812, its branch
// normalized to Gloas' 11 nodes), and its beacon body.
func finalizedHeader(tag string, proposer uint64, block execBlock, hashForm bool) lcHeader {
	body := newSparseTree(tag + " finalized body")
	h := lcHeader{}
	if hashForm {
		body.set(executionBlockHashDeneb, block.hash)
		h.blockHash = block.hash
		h.branch = normalize(body.branch(executionBlockHashDeneb), executionBranchDepthGloas)
	} else {
		body.set(executionPayloadIndex, block.payload.root())
		p := block.payload
		h.payload = &p
		h.branch = body.branch(executionPayloadIndex)
	}
	h.beacon = beaconHeader{Slot: finalizedSlot, ProposerIndex: proposer,
		ParentRoot: h32(tag, "finalized parent"), StateRoot: h32(tag, "finalized state"), BodyRoot: body.root()}
	return h
}

type update struct {
	attested, finalized lcHeader
	next                *committee
	nextBranch          [][]byte
	finalityBranch      [][]byte
	bits, sig           []byte
	finalizedExecution  []byte
	nonSigners          []int
	signers             committee
}

// buildUpdate builds an update attested at attestedSlot (Gloas) over
// finalized, signed at signatureSlot by signers, with an optional next
// committee.
func buildUpdate(tag string, finalized lcHeader, finalizedExecution []byte, signers committee, next *committee, nonSigners []int, keys map[int]*blst.SecretKey) update {
	state := newSparseTree(tag + " attested state")
	state.set(finalizedRootGloas, finalized.beacon.root())
	if next != nil {
		state.set(nextSyncCommitteeGloas, next.root())
	}
	body := newSparseTree(tag + " attested body")
	attestedHash := h32(tag, "attested parent block hash")
	body.set(executionBlockHashGloas, attestedHash)
	attested := lcHeader{
		beacon: beaconHeader{Slot: attestedSlot, ProposerIndex: 3,
			ParentRoot: h32(tag, "attested parent"), StateRoot: state.root(), BodyRoot: body.root()},
		blockHash: attestedHash,
		branch:    body.branch(executionBlockHashGloas),
	}
	ns := map[int]bool{}
	for _, i := range nonSigners {
		ns[i] = true
	}
	version := computeForkVersion((signatureSlot - 1) / slotsPerEpoch)
	if version != v(0x80) {
		panic("the signature slot must use the Gloas domain")
	}
	domain := computeDomain(domainSyncCommittee, version, gvr)
	msg := computeSigningRoot(attested.beacon.root(), domain)
	u := update{
		attested: attested, finalized: finalized, next: next,
		finalityBranch: state.branch(finalizedRootGloas),
		bits:           bits(ns), sig: signers.sign(msg, ns, keys),
		finalizedExecution: finalizedExecution, nonSigners: nonSigners, signers: signers,
	}
	if next != nil {
		u.nextBranch = state.branch(nextSyncCommitteeGloas)
	}
	return u
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// --- Gno output ---

type writer struct{ bytes.Buffer }

func (w *writer) f(format string, args ...any) { fmt.Fprintf(&w.Buffer, format, args...) }

func hx(b []byte) string { return fmt.Sprintf("h(%q)", hex.EncodeToString(b)) }

func blobs(bs [][]byte) string {
	if len(bs) == 0 {
		return "nil"
	}
	s := "[][]byte{"
	for _, b := range bs {
		s += hx(b) + ", "
	}
	return s + "}"
}

func (w *writer) lcHeader(h lcHeader) {
	b := h.beacon
	w.f("LightClientHeader{\nBeacon: BeaconBlockHeader{Slot: %d, ProposerIndex: %d, ParentRoot: %s, StateRoot: %s, BodyRoot: %s},\n",
		b.Slot, b.ProposerIndex, hx(b.ParentRoot), hx(b.StateRoot), hx(b.BodyRoot))
	if p := h.payload; p != nil {
		baseFee := make([]byte, 8)
		binary.BigEndian.PutUint64(baseFee, p.BaseFeePerGas)
		baseFee = bytes.TrimLeft(baseFee, "\x00")
		w.f("Execution: ExecutionPayloadHeader{ParentHash: %s, FeeRecipient: %s, StateRoot: %s, ReceiptsRoot: %s, LogsBloom: %s, PrevRandao: %s, BlockNumber: %d, GasLimit: %d, GasUsed: %d, Timestamp: %d, ExtraData: %s, BaseFeePerGas: %s, BlockHash: %s, TransactionsRoot: %s, WithdrawalsRoot: %s, BlobGasUsed: %d, ExcessBlobGas: %d},\n",
			hx(p.ParentHash), hx(p.FeeRecipient), hx(p.StateRoot), hx(p.ReceiptsRoot), hx(p.LogsBloom), hx(p.PrevRandao),
			p.BlockNumber, p.GasLimit, p.GasUsed, p.Timestamp, hx(p.ExtraData), hx(baseFee), hx(p.BlockHash),
			hx(p.TransactionsRoot), hx(p.WithdrawalsRoot), p.BlobGasUsed, p.ExcessBlobGas)
	} else {
		w.f("ExecutionBlockHash: %s,\n", hx(h.blockHash))
	}
	w.f("ExecutionBranch: %s,\n}", blobs(h.branch))
}

func (w *writer) update(u update) {
	w.f("LightClientUpdate{\nAttestedHeader: ")
	w.lcHeader(u.attested)
	w.f(",\n")
	if u.next != nil {
		w.f("NextSyncCommittee: &SummarizedSyncCommittee{PubkeysHash: %s, AggregatePubkey: %s},\n", hx(pubkeysRoot(u.next.pks)), hx(u.next.aggregate))
		w.f("NextSyncCommitteeBranch: %s,\n", blobs(u.nextBranch))
	}
	w.f("FinalizedHeader: ")
	w.lcHeader(u.finalized)
	w.f(",\nFinalityBranch: %s,\n", blobs(u.finalityBranch))
	w.f("SyncAggregate: SyncAggregate{SyncCommitteeBits: %s, SyncCommitteeSignature: %s},\n", hx(u.bits), hx(u.sig))
	w.f("SignatureSlot: %d,\n", signatureSlot)
	if u.finalizedExecution != nil {
		w.f("FinalizedExecutionHeader: %s,\n", hx(u.finalizedExecution))
	}
	if len(u.nonSigners) > 0 {
		w.f("NonSigners: []NonSigner{\n")
		for _, i := range u.nonSigners {
			w.f("{Pubkey: %s, Branch: %s},\n", hx(u.signers.pks[i]), blobs(pubkeyBranch(u.signers.pks, i)))
		}
		w.f("},\n")
	}
	w.f("}")
}

func (w *writer) header(name, doc string, u update) {
	w.f("\n// %s\nfunc %s() *Header {\nreturn &Header{TrustedSlot: %d, ConsensusUpdate: ", doc, name, trustedSlot)
	w.update(u)
	w.f("}\n}\n")
}

func generate() ([]byte, error) {
	current, next := newCommittee("period 2"), newCommittee("period 3")
	block := newExecBlock("finalized block", 1000, genesisTime+finalizedSlot*secondsPerSlot-secondsPerSlot)
	payloadForm := finalizedHeader("transition", 5, block, false)
	hashForm := finalizedHeader("transition", 5, block, true)

	transition := buildUpdate("transition", payloadForm, nil, current, &next, nil, nil)
	hashTransition := buildUpdate("hash form", hashForm, block.rlp, current, &next, nil, nil)
	conflicting := finalizedHeader("conflicting", 6, newExecBlock("conflicting block", 1000, block.header.Time), false)
	misbehaviour1 := buildUpdate("misbehaviour 1", payloadForm, nil, current, nil, nil, nil)
	misbehaviour2 := buildUpdate("misbehaviour 2", conflicting, nil, current, nil, nil, nil)
	nonSigners := []int{3, 10, 27}
	several := buildUpdate("non-signers", payloadForm, nil, current, nil, nonSigners, nil)
	wrongKey := buildUpdate("non-signers", payloadForm, nil, current, nil, nonSigners, map[int]*blst.SecretKey{14: outsider()})

	var w writer
	w.f("// Code generated by cmd/gen-eth-synthetic. DO NOT EDIT.\n\n")
	w.f("// Synthetic, spec-exact light-client data signed by a sync committee whose\n")
	w.f("// keys derive from a fixed seed: the cases recorded chains cannot give. See\n")
	w.f("// cmd/gen-eth-synthetic for how each is built.\n\npackage ethereum\n\n")

	w.f("// syntheticClientState is the synthetic chain: 2 s slots, 8-slot epochs,\n// 64-slot periods, Fulu at epoch 1 and Gloas at epoch %d (slot %d).\n", gloasEpoch, gloasEpoch*slotsPerEpoch)
	w.f("func syntheticClientState() ClientState {\nreturn ClientState{\nChainID: 7777, GenesisValidatorsRoot: %s, MinSyncCommitteeParticipants: %d, SyncCommitteeSize: %d, GenesisTime: %d, GenesisSlot: 0,\n",
		hx(gvr), minParticipants, committeeSize, genesisTime)
	w.f("ForkParameters: ForkParameters{GenesisForkVersion: [4]byte{0x%02x, 0, 0, 0x99}", genesisVersion[0])
	for _, fk := range forks {
		w.f(", %s: Fork{Version: [4]byte{0x%02x, 0, 0, 0x99}, Epoch: %d}", fk.name, fk.version[0], fk.epoch)
	}
	w.f("},\nSecondsPerSlot: %d, SlotsPerEpoch: %d, EpochsPerSyncCommitteePeriod: %d, LatestSlot: %d, LatestExecutionBlockNumber: 999, IBCContractAddress: h(%q), IBCCommitmentSlot: h(%q),\n}\n}\n",
		secondsPerSlot, slotsPerEpoch, epochsPerPeriod, trustedSlot, router, commitmentSlot)

	w.f("\n// syntheticConsensusState is the trusted state at slot %d (period 2): its\n// current committee signs every synthetic update; its next one is unknown.\n", trustedSlot)
	w.f("func syntheticConsensusState() ConsensusState {\nreturn ConsensusState{Slot: %d, StateRoot: %s, Timestamp: %d, CurrentSyncCommittee: SummarizedSyncCommittee{PubkeysHash: %s, AggregatePubkey: %s}}\n}\n",
		trustedSlot, hx(h32("trusted state root")), genesisTime+trustedSlot*secondsPerSlot, hx(pubkeysRoot(current.pks)), hx(current.aggregate))

	w.f("\n// syntheticNextCommittee is the committee the transition updates reveal.\nfunc syntheticNextCommittee() SummarizedSyncCommittee {\nreturn SummarizedSyncCommittee{PubkeysHash: %s, AggregatePubkey: %s}\n}\n",
		hx(pubkeysRoot(next.pks)), hx(next.aggregate))
	w.f("\n// syntheticFinalizedExecution is the finalized execution block: its state\n// root, timestamp and number.\nfunc syntheticFinalizedExecution() ([]byte, uint64, uint64) {\nreturn %s, %d, %d\n}\n",
		hx(block.header.StateRoot), block.header.Time, block.header.Number)

	w.header("syntheticTransition", "syntheticTransition is attested at slot 144 (Gloas: gindices 735, 2946 and 2856) and\n// signed at 145 under the Gloas domain, finalizing slot 136 (Fulu) with its\n// payload header at gindex 25, and reveals the next committee.", transition)
	w.header("syntheticHashFormTransition", "syntheticHashFormTransition is syntheticTransition with the finalized\n// header in Gloas' block-hash form (gindex 812, an 11-node normalized branch)\n// and its RLP execution header.", hashTransition)
	w.f("\n// syntheticMisbehaviour is two valid updates finalizing different beacon\n// headers at slot 136, each signed by the whole committee.\nfunc syntheticMisbehaviour() *Misbehaviour {\nreturn &Misbehaviour{TrustedSlot: %d, Update1: ", trustedSlot)
	w.update(misbehaviour1)
	w.f(", Update2: ")
	w.update(misbehaviour2)
	w.f("}\n}\n")
	w.header("syntheticNonSigners", "syntheticNonSigners is signed by every member but 3, 10 and 27, listed\n// with their branches in committee order.", several)
	w.f("\n// syntheticOutsiderSignature is syntheticNonSigners' signature with\n// member 14's share made by a key outside the committee.\nfunc syntheticOutsiderSignature() []byte {\nreturn %s\n}\n", hx(wrongKey.sig))

	return format.Source(w.Bytes())
}
