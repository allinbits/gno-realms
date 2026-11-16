package ethereum

import (
	"bytes"
	"testing"

	"gno.land/p/aib/encoding/wire/v0"
	"gno.land/p/nt/urequire/v0"
)

// The test encoder of the wire format the decoders read (see wire.gno).

func encBlobs(w *wire.Writer, bs [][]byte) {
	w.Uvarint(uint64(len(bs)))
	for _, b := range bs {
		w.Blob(b)
	}
}

func encLCHeader(w *wire.Writer, h LightClientHeader) {
	b := h.Beacon
	w.Uint(b.Slot).Uint(b.ProposerIndex).Blob(b.ParentRoot).Blob(b.StateRoot).Blob(b.BodyRoot)
	if h.hashForm() {
		w.Byte(1).Blob(h.ExecutionBlockHash)
	} else {
		e := h.Execution
		w.Byte(0).Blob(e.ParentHash).Blob(e.FeeRecipient).Blob(e.StateRoot).Blob(e.ReceiptsRoot).
			Blob(e.LogsBloom).Blob(e.PrevRandao).
			Uint(e.BlockNumber).Uint(e.GasLimit).Uint(e.GasUsed).Uint(e.Timestamp).
			Blob(e.ExtraData).Blob(e.BaseFeePerGas).Blob(e.BlockHash).
			Blob(e.TransactionsRoot).Blob(e.WithdrawalsRoot).
			Uint(e.BlobGasUsed).Uint(e.ExcessBlobGas)
	}
	encBlobs(w, h.ExecutionBranch)
}

func encUpdate(w *wire.Writer, u LightClientUpdate) {
	encLCHeader(w, u.AttestedHeader)
	w.Bool(u.NextSyncCommittee != nil)
	if u.NextSyncCommittee != nil {
		w.Blob(u.NextSyncCommittee.PubkeysHash).Blob(u.NextSyncCommittee.AggregatePubkey)
		encBlobs(w, u.NextSyncCommitteeBranch)
	}
	encLCHeader(w, u.FinalizedHeader)
	encBlobs(w, u.FinalityBranch)
	w.Blob(u.SyncAggregate.SyncCommitteeBits).Blob(u.SyncAggregate.SyncCommitteeSignature).
		Uint(u.SignatureSlot).Blob(u.FinalizedExecutionHeader)
	w.Uvarint(uint64(len(u.NonSigners)))
	for _, ns := range u.NonSigners {
		w.Blob(ns.Pubkey)
		encBlobs(w, ns.Branch)
	}
}

func encHeader(h *Header) []byte {
	w := wire.NewWriter().Uint(h.TrustedSlot).Bool(h.ActiveIsNext)
	encUpdate(w, h.ConsensusUpdate)
	return w.Bytes()
}

// A header round-trips through the decoder and still verifies, in either
// execution form; truncated input, trailing bytes, an unknown header kind and
// a list count the input cannot hold are refused.
func TestDecodeHeader(t *testing.T) {
	c, hdr := erc20First(t, nil)
	hdr.ConsensusUpdate.AttestedHeader = hashForm(hdr.ConsensusUpdate.AttestedHeader)
	bz := encHeader(hdr)
	got, err := DecodeHeader(bz)
	urequire.NoError(t, err)
	urequire.True(t, bytes.Equal(encHeader(got), bz), "re-encoding gives the same bytes")
	urequire.True(t, got.ConsensusUpdate.AttestedHeader.hashForm() && !got.ConsensusUpdate.FinalizedHeader.hashForm())
	urequire.NoError(t, verifyAt(c, got))

	for _, n := range []int{0, 1, 8, 9, 50, len(bz) / 2, len(bz) - 1} {
		_, err := DecodeHeader(bz[:n])
		urequire.Error(t, err, "truncated")
	}
	_, err = DecodeHeader(append(append([]byte{}, bz...), 0))
	urequire.ErrorContains(t, err, "trailing bytes")

	// The attested header's kind byte follows its slot, proposer index and
	// three 32-byte roots (each blob a 1-byte length and 32 bytes).
	kindAt := 8 + 1 + 8 + 8 + 3*33
	urequire.Equal(t, byte(1), bz[kindAt])
	bad := append([]byte{}, bz...)
	bad[kindAt] = 2
	_, err = DecodeHeader(bad)
	urequire.ErrorContains(t, err, "unknown light-client header kind")

	m := wire.NewWriter().Uvarint(1000).Blob([]byte{1}).Bytes()
	_, err = DecodeMembershipProof(m)
	urequire.ErrorContains(t, err, "list longer than the remaining bytes")

	mb := wire.NewWriter().Uint(hdr.TrustedSlot).Bool(false)
	encUpdate(mb, hdr.ConsensusUpdate)
	encUpdate(mb, hdr.ConsensusUpdate)
	mis, err := DecodeMisbehaviour(mb.Bytes())
	urequire.NoError(t, err)
	urequire.Equal(t, hdr.ConsensusUpdate.SignatureSlot, mis.Update2.SignatureSlot)
}
