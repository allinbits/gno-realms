// Command gen-eth-synthetic writes synthetic Ethereum light-client test
// data for gno.land/p/aib/ibc/lightclient/ethereum, built from the specs as
// described below: the cases recorded chains cannot give, signed by a sync
// committee whose BLS keys it derives from a fixed seed.
//
// Canonical, as the gloas light-client sync protocol has them:
//   - a Gloas update (attested and signed in Gloas) whose finalized header is
//     still Fulu, upgraded to the block-hash form (gindex 812) with its full
//     RLP execution header, as upgrade_lc_header_to_gloas gives it;
//   - two such updates finalizing different headers at one slot
//     (conflicting-finality misbehaviour);
//   - such an update with several non-signers, and a signature with a share
//     by a key outside the committee;
//   - a Fulu update (attested, finalized and signed in Fulu), both headers
//     with their execution payload header (gindex 25).
//
// And one client-compatibility case, outside the spec: the Gloas update with
// its Fulu finalized header left in the payload form, which a Gloas
// LightClientHeader cannot hold but this client accepts.
//
// It is written from the consensus specs (ssz, phase0 to gloas beacon-chain,
// the light-client sync protocols), the ssz-specs progressive merkleization
// rules and the execution block header layout, not from the gno client: SSZ
// roots, domains and signing roots are computed here, and signatures come
// from blst, while the client verifies with a native that wraps gnark-crypto.
// The attested beacon states and bodies, and every block's execution payload,
// are built as their containers (Gloas' as progressive containers). Set to
// the value a spec rule gives them:
//   - every basic field (slots, epochs, fork versions, uint64 counters,
//     padding), active-fields word, zero padding and progressive terminator;
//   - the state's finalized checkpoint, sync committees, fork and
//     latest_block_header (the block's header with a zero state root);
//   - Gloas: the bid's parent_block_root (the block's parent) and slot, the
//     state's latest_execution_payload_bid (the body's bid) and
//     latest_block_hash (the bid's parent_block_hash), empty deposits;
//   - Fulu: the state's latest_execution_payload_header (the payload);
//   - every operation list, blob commitment list and execution request list
//     empty, in both forks, and the execution payloads empty blocks: no
//     transactions, withdrawals, receipts, blob gas or requests, so their
//     SSZ and RLP roots are the empty ones, the bloom is zero and no gas is
//     used; each payload's timestamp is its slot's time, and its RLP
//     parent_beacon_block_root its beacon block's parent (EIP-4788).
//
// Arbitrary, derived from the seed, are the fields whose rules tie them only
// to history this does not model: the beacon headers' parent roots and the
// finalized header's state root; randao reveals and mixes and the payloads'
// prev_randao; eth1 data and votes; sync aggregates; block and state root
// vectors, historical roots and summaries; validators, balances,
// participation, inactivity scores, slashings and pending queues; the
// proposer lookahead; Gloas' builders, builder payments and withdrawals,
// payload availability, expected withdrawals, PTC window, the bid's
// block_hash, prev_randao, execution_requests_root and signature; the
// payloads' parent hash, state root, coinbase and extra data; and the
// justified checkpoints' roots.
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
// to Electra at genesis, Fulu at epoch 1, Gloas at epoch 20 (slot 160). Every
// update finalizes the checkpoint of epoch 17, at least two epochs before its
// attested head, as a finalizing chain does.
const (
	seed            = "gno-realms synthetic ethereum light-client fixtures v2"
	committeeSize   = 32
	minParticipants = 11
	genesisTime     = 1700000000
	secondsPerSlot  = 2
	slotsPerEpoch   = 8
	epochsPerPeriod = 8
	fuluEpoch       = 1
	gloasEpoch      = 20
	trustedSlot     = 128 // period 2
	finalizedSlot   = 136 // the first slot of epoch 17: Fulu
	finalizedEpoch  = finalizedSlot / slotsPerEpoch
	gloasAttested   = 160 // epoch 20: Gloas
	gloasSignature  = 161 // signature_slot - 1 = 160: the Gloas domain
	fuluAttested    = 152 // epoch 19: Fulu
	fuluSignature   = 153 // signature_slot - 1 = 152: the Fulu domain
	router          = "1d95d544586eacb63b6154e9e45122b32ded11aa"
	commitmentSlot  = "1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600"

	// Generalized indices (electra and gloas light-client sync protocols);
	// the trees below land the leaves there, which build() checks.
	finalizedRootElectra      = 169
	nextSyncCommitteeElectra  = 87
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
		{"Deneb", v(0x50), 0}, {"Electra", v(0x60), 0}, {"Fulu", v(0x70), fuluEpoch},
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

func newExecBlock(tag string, number, slot uint64, parentBeaconRoot []byte) execBlock {
	// An empty block: no transactions, withdrawals, blobs or requests, so
	// every root committing to them is the empty one, the bloom is zero and
	// no gas is used.
	emptyTrie := mustHex("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421") // keccak(rlp(""))
	eh := executionHeader{
		ParentHash:   h32(tag, "parent"),
		OmmersHash:   mustHex("1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"), // keccak(rlp([]))
		Coinbase:     h32(tag, "coinbase")[:20],
		StateRoot:    h32(tag, "state root"),
		TxRoot:       emptyTrie,
		ReceiptsRoot: emptyTrie,
		Bloom:        make([]byte, 256),
		Number:       number, GasLimit: 30_000_000, GasUsed: 0,
		// process_execution_payload: the payload's timestamp is its own
		// slot's time.
		Time:            genesisTime + slot*secondsPerSlot,
		Extra:           []byte("synthetic"),
		MixDigest:       h32(tag, "prev randao"),
		Nonce:           make([]byte, 8),
		BaseFee:         7,
		WithdrawalsRoot: emptyTrie,
		BlobGasUsed:     0,
		ExcessBlobGas:   0,
		// EIP-4788: the parent beacon block's root.
		ParentBeaconRoot: parentBeaconRoot,
		// EIP-7685: SHA256 over no request digests.
		RequestsHash: sha(),
	}
	b := execBlock{header: eh, rlp: eh.rlp()}
	b.hash = keccak(b.rlp)
	b.payload = payloadHeader{
		ParentHash: eh.ParentHash, FeeRecipient: eh.Coinbase, StateRoot: eh.StateRoot,
		ReceiptsRoot: eh.ReceiptsRoot, LogsBloom: eh.Bloom, PrevRandao: eh.MixDigest,
		BlockNumber: eh.Number, GasLimit: eh.GasLimit, GasUsed: eh.GasUsed, Timestamp: eh.Time,
		ExtraData: eh.Extra, BaseFeePerGas: eh.BaseFee, BlockHash: b.hash,
		// Empty List[Transaction, 2^20] and List[Withdrawal, 16].
		TransactionsRoot: emptyList(20).root, WithdrawalsRoot: emptyList(4).root,
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

// arb is the root of a field nothing here depends on: a list, a signature or
// an unrelated container, any chunk of which is a possible root.
func arb(tag, field string) *node { return leaf(h32(tag, field)) }

func u64(x uint64) *node { return leaf(uint64Leaf(x)) }

// forkContainer is hash_tree_root(Fork) at epoch.
func forkContainer(epoch uint64) *node {
	cur := computeForkVersion(epoch)
	prev, since := genesisVersion, uint64(0)
	for i := len(forks) - 1; i >= 0; i-- {
		if epoch >= forks[i].epoch {
			since = forks[i].epoch
			for j := i - 1; j >= 0; j-- {
				if forks[j].epoch < since {
					prev = forks[j].version
					break
				}
			}
			break
		}
	}
	return container(leaf(padRight(prev[:])), leaf(padRight(cur[:])), u64(since))
}

func checkpoint(epoch uint64, root []byte) *node { return container(u64(epoch), leaf(root)) }

// fuluBody is a Fulu (Electra) BeaconBlockBody holding payload.
func fuluBody(tag string, payload payloadHeader) *node {
	// Empty operation lists (limits 16, 1, 8, 16, 16, 16 and 4096: chunk
	// depths 4, 0, 3, 4, 4, 4 and 12), no blob commitments (the payload uses
	// no blob gas) and empty execution requests (the payload's requests_hash
	// is the empty one): List[DepositRequest, 8192], List[WithdrawalRequest,
	// 16], List[ConsolidationRequest, 2].
	return container(
		arb(tag, "randao_reveal"), arb(tag, "eth1_data"), arb(tag, "graffiti"),
		emptyList(4), emptyList(0), emptyList(3),
		emptyList(4), emptyList(4), arb(tag, "sync_aggregate"),
		payload.tree(), // execution_payload: field 9, gindex 25
		emptyList(4), emptyList(12), container(emptyList(13), emptyList(4), emptyList(1)),
	)
}

// gloasBody is a Gloas BeaconBlockBody (a ProgressiveContainer) whose
// signed bid commits to parentBlockHash at slot.
// It returns the body and its bid, which the state records.
func gloasBody(tag string, slot, parentBlockHash, parentBlockRoot []byte) (*node, *node) {
	// process_execution_payload_bid: parent_block_root is the block's parent.
	bid := progressiveContainer( // ExecutionPayloadBid
		leaf(parentBlockHash), leaf(parentBlockRoot), arb(tag, "block_hash"), arb(tag, "prev_randao"),
		leaf(padRight(h32(tag, "fee_recipient")[:20])), u64(30_000_000), u64(4), leaf(slot),
		u64(1_000_000_000), u64(0), emptyProgressiveList(), arb(tag, "execution_requests_root"),
	)
	signed := container(bid, arb(tag, "bid signature"))
	// Empty operation lists, deposits included (Gloas requires them empty),
	// and empty parent execution requests: every list a ProgressiveList.
	empty := emptyProgressiveList
	body := progressiveContainer(
		arb(tag, "randao_reveal"), arb(tag, "eth1_data"), arb(tag, "graffiti"),
		empty(), empty(), empty(),
		empty(), empty(), arb(tag, "sync_aggregate"),
		empty(),
		signed, // signed_execution_payload_bid: field 10, its parent_block_hash at gindex 2856
		empty(), progressiveContainer(empty(), empty(), empty(), empty(), empty()),
	)
	return body, bid
}

// latestBlockHeader is state.latest_block_header after process_block_header:
// the block's header with a zero state root.
func latestBlockHeader(slot, proposer uint64, parentRoot, bodyRoot []byte) *node {
	return container(u64(slot), u64(proposer), leaf(parentRoot), leaf(zero()), leaf(bodyRoot))
}

// fuluState is a Fulu BeaconState at slot finalizing finalizedRoot, with the
// given sync committees.
func fuluState(tag string, slot uint64, latestHeader *node, finalizedRoot []byte, current committee, next *node, latestPayload []byte) *node {
	return container(
		u64(genesisTime), leaf(gvr), u64(slot), forkContainer(slot/slotsPerEpoch),
		latestHeader, arb(tag, "block_roots"), arb(tag, "state_roots"), arb(tag, "historical_roots"),
		arb(tag, "eth1_data"), arb(tag, "eth1_data_votes"), u64(0), arb(tag, "validators"), arb(tag, "balances"),
		arb(tag, "randao_mixes"), arb(tag, "slashings"), arb(tag, "previous_epoch_participation"),
		arb(tag, "current_epoch_participation"), leaf(padRight([]byte{0x0f})),
		checkpoint(finalizedEpoch+1, h32(tag, "previous justified")), checkpoint(finalizedEpoch+1, h32(tag, "current justified")),
		checkpoint(finalizedEpoch, finalizedRoot), // finalized_checkpoint: field 20, its root at gindex 169
		arb(tag, "inactivity_scores"), leaf(current.root()),
		next, // next_sync_committee: field 23, gindex 87
		leaf(latestPayload), u64(0), u64(0), arb(tag, "historical_summaries"), u64(0), u64(0), u64(0), u64(0), u64(0), u64(0),
		arb(tag, "pending_deposits"), arb(tag, "pending_partial_withdrawals"), arb(tag, "pending_consolidations"),
		arb(tag, "proposer_lookahead"),
	)
}

// gloasState is a Gloas BeaconState (a ProgressiveContainer) at slot.
func gloasState(tag string, slot uint64, latestHeader *node, finalizedRoot []byte, current committee, next *node, latestBlockHash []byte, bid *node) *node {
	return progressiveContainer(
		u64(genesisTime), leaf(gvr), u64(slot), forkContainer(slot/slotsPerEpoch),
		latestHeader, arb(tag, "block_roots"), arb(tag, "state_roots"), arb(tag, "historical_roots"),
		arb(tag, "eth1_data"), arb(tag, "eth1_data_votes"), u64(0), arb(tag, "validators"), arb(tag, "balances"),
		arb(tag, "randao_mixes"), arb(tag, "slashings"), arb(tag, "previous_epoch_participation"),
		arb(tag, "current_epoch_participation"), leaf(padRight([]byte{0x0f})),
		checkpoint(finalizedEpoch+1, h32(tag, "previous justified")), checkpoint(finalizedEpoch+1, h32(tag, "current justified")),
		checkpoint(finalizedEpoch, finalizedRoot), // finalized_checkpoint: field 20, its root at gindex 735
		arb(tag, "inactivity_scores"), leaf(current.root()),
		next, // next_sync_committee: field 23, gindex 2946
		leaf(latestBlockHash), u64(0), u64(0), arb(tag, "historical_summaries"), u64(0), u64(0), u64(0), u64(0), u64(0), u64(0),
		arb(tag, "pending_deposits"), arb(tag, "pending_partial_withdrawals"), arb(tag, "pending_consolidations"),
		arb(tag, "proposer_lookahead"), arb(tag, "builders"), u64(0), arb(tag, "execution_payload_availability"),
		arb(tag, "builder_pending_payments"), arb(tag, "builder_pending_withdrawals"), bid, // process_execution_payload_bid records the block's bid
		arb(tag, "payload_expected_withdrawals"), arb(tag, "ptc_window"),
	)
}

// finalizedHeader is the Fulu finalized header of block, at the first slot
// of the finalized epoch: in Gloas' block-hash form (gindex 812, its branch
// the payload's own proof extended by the body's and normalized to Gloas' 11
// nodes, as upgrade_lc_header_to_gloas builds it), or in the payload form
// (gindex 25).
func finalizedHeader(tag string, proposer uint64, block execBlock, parentRoot []byte, hashForm bool) lcHeader {
	body := fuluBody(tag+" finalized body", block.payload)
	h := lcHeader{beacon: beaconHeader{Slot: finalizedSlot, ProposerIndex: proposer,
		ParentRoot: parentRoot, StateRoot: h32(tag, "finalized state"), BodyRoot: body.root}}
	if !bytes.Equal(body.at(executionPayloadIndex).root, block.payload.root()) || !bytes.Equal(body.at(executionBlockHashDeneb).root, block.hash) {
		panic("the Fulu body does not hold the payload at gindex 25 and its block hash at 812")
	}
	if hashForm {
		h.blockHash = block.hash
		h.branch = normalize(body.branch(executionBlockHashDeneb), executionBranchDepthGloas)
	} else {
		p := block.payload
		h.payload = &p
		h.branch = body.branch(executionPayloadIndex)
	}
	return h
}

type update struct {
	attested, finalized lcHeader
	next                *committee
	nextBranch          [][]byte
	finalityBranch      [][]byte
	bits, sig           []byte
	signatureSlot       uint64
	finalizedExecution  []byte
	nonSigners          []int
	signers             committee
}

type updateSpec struct {
	tag                string
	gloas              bool // attested and signed in Gloas, or in Fulu
	finalized          lcHeader
	finalizedExecution []byte
	signers            committee
	stateNext          committee  // the attested state's next committee
	next               *committee // the next committee the update carries
	nonSigners         []int
	keys               map[int]*blst.SecretKey
}

// build builds the update spec describes: the attested beacon state and
// body as their containers, the finality and next-committee branches read
// from the state, and the committee's signature over the attested header.
func build(spec updateSpec) update {
	tag := spec.tag
	attestedSlot, sigSlot := uint64(fuluAttested), uint64(fuluSignature)
	if spec.gloas {
		attestedSlot, sigSlot = gloasAttested, gloasSignature
	}
	// The state's next committee is the next period's whether or not the
	// update carries it.
	nextLeaf := leaf(spec.stateNext.root())
	parentRoot := h32(tag, "attested parent")
	finalizedRoot := spec.finalized.beacon.root()
	var state, body *node
	var attested lcHeader
	finIdx, nextIdx := uint64(finalizedRootElectra), uint64(nextSyncCommitteeElectra)
	if spec.gloas {
		parentHash := h32(tag, "attested parent block hash")
		var bid *node
		body, bid = gloasBody(tag+" attested body", uint64Leaf(attestedSlot), parentHash, parentRoot)
		state = gloasState(tag+" attested state", attestedSlot, latestBlockHeader(attestedSlot, 3, parentRoot, body.root),
			finalizedRoot, spec.signers, nextLeaf, parentHash, bid)
		attested = lcHeader{blockHash: parentHash, branch: body.branch(executionBlockHashGloas)}
		if !bytes.Equal(body.at(executionBlockHashGloas).root, parentHash) {
			panic("the Gloas body does not hold the bid's parent block hash at 2856")
		}
		finIdx, nextIdx = finalizedRootGloas, nextSyncCommitteeGloas
	} else {
		block := newExecBlock(tag+" attested block", 1016, attestedSlot, parentRoot)
		body = fuluBody(tag+" attested body", block.payload)
		state = fuluState(tag+" attested state", attestedSlot, latestBlockHeader(attestedSlot, 3, parentRoot, body.root),
			finalizedRoot, spec.signers, nextLeaf, block.payload.root())
		p := block.payload
		attested = lcHeader{payload: &p, branch: body.branch(executionPayloadIndex)}
	}
	if !bytes.Equal(state.at(finIdx).root, finalizedRoot) || !bytes.Equal(state.at(nextIdx).root, nextLeaf.root) {
		panic("the state does not hold the finalized root and the next committee at their gindices")
	}
	attested.beacon = beaconHeader{Slot: attestedSlot, ProposerIndex: 3,
		ParentRoot: parentRoot, StateRoot: state.root, BodyRoot: body.root}

	ns := map[int]bool{}
	for _, i := range spec.nonSigners {
		ns[i] = true
	}
	version := computeForkVersion((sigSlot - 1) / slotsPerEpoch)
	domain := computeDomain(domainSyncCommittee, version, gvr)
	msg := computeSigningRoot(attested.beacon.root(), domain)
	u := update{
		attested: attested, finalized: spec.finalized, next: spec.next,
		finalityBranch: state.branch(finIdx),
		bits:           bits(ns), sig: spec.signers.sign(msg, ns, spec.keys), signatureSlot: sigSlot,
		finalizedExecution: spec.finalizedExecution, nonSigners: spec.nonSigners, signers: spec.signers,
	}
	if spec.next != nil {
		u.nextBranch = state.branch(nextIdx)
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
	w.f("SignatureSlot: %d,\n", u.signatureSlot)
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
	parent := h32("finalized parent")
	block := newExecBlock("finalized block", 1000, finalizedSlot, parent)
	hashForm := finalizedHeader("finalized", 5, block, parent, true)
	payloadForm := finalizedHeader("finalized", 5, block, parent, false)
	conflictingParent := h32("conflicting parent")
	conflictingBlock := newExecBlock("conflicting block", 1000, finalizedSlot, conflictingParent)
	conflicting := finalizedHeader("conflicting", 6, conflictingBlock, conflictingParent, true)

	transition := build(updateSpec{tag: "gloas", gloas: true, finalized: hashForm, finalizedExecution: block.rlp, signers: current, stateNext: next, next: &next})
	mixed := build(updateSpec{tag: "mixed form", gloas: true, finalized: payloadForm, signers: current, stateNext: next, next: &next})
	fulu := build(updateSpec{tag: "fulu", finalized: payloadForm, signers: current, stateNext: next, next: &next})
	misbehaviour1 := build(updateSpec{tag: "misbehaviour 1", gloas: true, finalized: hashForm, finalizedExecution: block.rlp, signers: current, stateNext: next})
	misbehaviour2 := build(updateSpec{tag: "misbehaviour 2", gloas: true, finalized: conflicting, finalizedExecution: conflictingBlock.rlp, signers: current, stateNext: next})
	nonSigners := []int{3, 10, 27}
	several := updateSpec{tag: "non-signers", gloas: true, finalized: hashForm, finalizedExecution: block.rlp, signers: current, stateNext: next, nonSigners: nonSigners}
	withNonSigners := build(several)
	several.keys = map[int]*blst.SecretKey{14: outsider()}
	wrongKey := build(several)

	var w writer
	w.f("// Code generated by cmd/gen-eth-synthetic. DO NOT EDIT.\n\n")
	w.f("// Synthetic light-client data, built from the specs, signed by a sync committee whose\n")
	w.f("// keys derive from a fixed seed: the cases recorded chains cannot give. See\n")
	w.f("// cmd/gen-eth-synthetic for how each is built.\n\npackage ethereum\n\n")

	w.f("// syntheticClientState is the synthetic chain: 2 s slots, 8-slot epochs,\n// 64-slot periods, Fulu at epoch %d and Gloas at epoch %d (slot %d).\n", fuluEpoch, gloasEpoch, gloasEpoch*slotsPerEpoch)
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
	w.f("\n// syntheticFinalizedExecution is the finalized execution block: its state\n// root, timestamp (its slot's time) and number.\nfunc syntheticFinalizedExecution() ([]byte, uint64, uint64) {\nreturn %s, %d, %d\n}\n",
		hx(block.header.StateRoot), block.header.Time, block.header.Number)

	w.header("syntheticGloasTransition", "syntheticGloasTransition is a canonical Gloas update: attested at slot 160\n// (gindices 735, 2946 and 2856) and signed at 161 under the Gloas domain,\n// finalizing slot 136, a Fulu header upgraded to the block-hash form\n// (gindex 812, an 11-node normalized branch), with its RLP execution header.\n// It reveals the next committee.", transition)
	w.header("syntheticMixedFormTransition", "syntheticMixedFormTransition is a client-compatibility case outside the\n// spec: syntheticGloasTransition with its Fulu finalized header left in the\n// payload form (gindex 25), which a Gloas LightClientHeader cannot hold.", mixed)
	w.header("syntheticFuluUpdate", "syntheticFuluUpdate is a Fulu update: attested at slot 152 (gindices 169\n// and 87) and signed at 153 under the Fulu domain, both headers with their\n// execution payload header (gindex 25). It reveals the next committee.", fulu)
	w.f("\n// syntheticMisbehaviour is two canonical Gloas updates finalizing different\n// Fulu headers at slot 136, each signed by the whole committee.\nfunc syntheticMisbehaviour() *Misbehaviour {\nreturn &Misbehaviour{TrustedSlot: %d, Update1: ", trustedSlot)
	w.update(misbehaviour1)
	w.f(", Update2: ")
	w.update(misbehaviour2)
	w.f("}\n}\n")
	w.header("syntheticNonSigners", "syntheticNonSigners is a canonical Gloas update signed by every member but\n// 3, 10 and 27, listed with their branches in committee order.", withNonSigners)
	w.f("\n// syntheticOutsiderSignature is syntheticNonSigners' signature with\n// member 14's share made by a key outside the committee.\nfunc syntheticOutsiderSignature() []byte {\nreturn %s\n}\n", hx(wrongKey.sig))

	return format.Source(w.Bytes())
}
