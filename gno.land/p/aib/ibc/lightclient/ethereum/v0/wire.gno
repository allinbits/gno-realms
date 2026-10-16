package ethereum

import (
	"errors"

	"gno.land/p/aib/encoding/wire/v0"
)

// Binary encodings of the client messages and proofs, in the positional wire
// format of gno.land/p/aib/encoding/wire: relayers pass them as []byte MsgCall
// arguments, which the VM base64-decodes natively, so a message costs neither
// MsgRun preprocessing nor interpreted parsing beyond slicing its fields.
//
// Schema (field order is the format; "list" is a Uvarint count followed by
// the elements, "blob" a Uvarint length followed by the bytes):
//
//	Header:          Uint trusted_slot, Bool active_is_next, Update
//	Misbehaviour:    Uint trusted_slot, Bool active_is_next, Update, Update
//	Update:          LCHeader attested, Bool has_next,
//	                 [has_next: blob pubkeys_hash, blob aggregate_pubkey, list<blob> next_branch],
//	                 LCHeader finalized, list<blob> finality_branch,
//	                 blob bits, blob signature, Uint signature_slot,
//	                 blob finalized_execution_header,
//	                 list<NonSigner>
//	NonSigner:       blob pubkey, list<blob> branch
//	LCHeader:        Uint slot, Uint proposer_index, blob parent_root, blob state_root,
//	                 blob body_root, Byte kind (0 payload header, 1 block hash),
//	                 [kind 0: ExecutionPayloadHeader] [kind 1: blob block_hash],
//	                 list<blob> execution_branch
//	ExecutionPayloadHeader: blob parent_hash, blob fee_recipient, blob state_root,
//	                 blob receipts_root, blob logs_bloom, blob prev_randao,
//	                 Uint block_number, Uint gas_limit, Uint gas_used, Uint timestamp,
//	                 blob extra_data, blob base_fee_per_gas (big-endian),
//	                 blob block_hash, blob transactions_root, blob withdrawals_root,
//	                 Uint blob_gas_used, Uint excess_blob_gas
//	MembershipProof: list<blob> account_proof, list<blob> storage_proof

var (
	errTrailing   = errors.New("wire: trailing bytes")
	errListLength = errors.New("wire: list longer than the remaining bytes")
	errHeaderKind = errors.New("wire: unknown light-client header kind")
)

// decoder is a wire.Reader that also records errors of its own, such as a
// list count the remaining bytes cannot hold.
type decoder struct {
	*wire.Reader
	err error
}

func newDecoder(bz []byte) *decoder { return &decoder{Reader: wire.NewReader(bz)} }

func (d *decoder) ok() bool { return d.err == nil && d.Err() == nil }

// done returns the first decoding error, or rejects trailing bytes.
func (d *decoder) done() error {
	if d.err != nil {
		return d.err
	}
	if err := d.Err(); err != nil {
		return err
	}
	if !d.Done() {
		return errTrailing
	}
	return nil
}

// DecodeHeader decodes a Header.
func DecodeHeader(bz []byte) (*Header, error) {
	d := newDecoder(bz)
	h := &Header{TrustedSlot: d.Uint(), ActiveIsNext: d.Bool()}
	h.ConsensusUpdate = d.update()
	return h, d.done()
}

// DecodeMisbehaviour decodes a Misbehaviour.
func DecodeMisbehaviour(bz []byte) (*Misbehaviour, error) {
	d := newDecoder(bz)
	m := &Misbehaviour{TrustedSlot: d.Uint(), ActiveIsNext: d.Bool()}
	m.Update1 = d.update()
	m.Update2 = d.update()
	return m, d.done()
}

// DecodeMembershipProof decodes a MembershipProof.
func DecodeMembershipProof(bz []byte) (MembershipProof, error) {
	d := newDecoder(bz)
	p := MembershipProof{AccountProof: d.blobs(), StorageProof: d.blobs()}
	return p, d.done()
}

// count reads a list length, rejecting one the remaining bytes cannot hold
// (every element takes at least one byte) before anything is allocated.
func (d *decoder) count() int {
	n := d.Uvarint()
	if !d.ok() {
		return 0
	}
	if n > uint64(d.Remaining()) {
		d.err = errListLength
		return 0
	}
	return int(n)
}

func (d *decoder) blobs() [][]byte {
	n := d.count()
	out := make([][]byte, n)
	for i := 0; i < n && d.ok(); i++ {
		out[i] = d.Blob()
	}
	return out
}

func (d *decoder) update() LightClientUpdate {
	var u LightClientUpdate
	u.AttestedHeader = d.lcHeader()
	if d.Bool() {
		u.NextSyncCommittee = &SummarizedSyncCommittee{PubkeysHash: d.Blob(), AggregatePubkey: d.Blob()}
		u.NextSyncCommitteeBranch = d.blobs()
	}
	u.FinalizedHeader = d.lcHeader()
	u.FinalityBranch = d.blobs()
	u.SyncAggregate = SyncAggregate{SyncCommitteeBits: d.Blob(), SyncCommitteeSignature: d.Blob()}
	u.SignatureSlot = d.Uint()
	u.FinalizedExecutionHeader = d.Blob()
	n := d.count()
	u.NonSigners = make([]NonSigner, n)
	for i := 0; i < n && d.ok(); i++ {
		u.NonSigners[i] = NonSigner{Pubkey: d.Blob(), Branch: d.blobs()}
	}
	return u
}

func (d *decoder) lcHeader() LightClientHeader {
	var h LightClientHeader
	h.Beacon = BeaconBlockHeader{
		Slot: d.Uint(), ProposerIndex: d.Uint(),
		ParentRoot: d.Blob(), StateRoot: d.Blob(), BodyRoot: d.Blob(),
	}
	switch kind := d.Byte(); {
	case !d.ok():
	case kind == 0:
		h.Execution = ExecutionPayloadHeader{
			ParentHash: d.Blob(), FeeRecipient: d.Blob(), StateRoot: d.Blob(), ReceiptsRoot: d.Blob(),
			LogsBloom: d.Blob(), PrevRandao: d.Blob(),
			BlockNumber: d.Uint(), GasLimit: d.Uint(), GasUsed: d.Uint(), Timestamp: d.Uint(),
			ExtraData: d.Blob(), BaseFeePerGas: d.Blob(), BlockHash: d.Blob(),
			TransactionsRoot: d.Blob(), WithdrawalsRoot: d.Blob(),
			BlobGasUsed: d.Uint(), ExcessBlobGas: d.Uint(),
		}
	case kind == 1:
		h.ExecutionBlockHash = d.Blob()
	default:
		d.err = errHeaderKind
	}
	h.ExecutionBranch = d.blobs()
	return h
}
