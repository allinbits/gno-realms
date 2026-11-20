package ics23_test

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"

	"gno.land/p/aib/ics23/v0"
	"gno.land/p/nt/urequire/v0"
)

// MerkleProofs ibc-go encoded (commitmenttypes.MerkleProof.Marshal) for an
// IAVL store "ibc" holding the keys 0x11, 0x32, 0x50, 0x72 and 0x99 (each its
// own value) under a rootmulti store whose app hash is merkleRoot: the
// existence of 0x32 and the absence of 0x60.
const (
	merkleRoot = "0bf78966a0d3b7acd9942a243c93ce7ab63ae0c7ff122fceafc6a09e44722cfe"

	existProofHex = "0a6d0a6b0a01321201321a0b0801180120012a0300020222290801122502040220154b101a72acffe0f5e65d1e144a57" +
		"dc6f97758d2049821231f02b6a5b44fe8120222b08011204060a02201a2120d7a40b1bb9f7d907a409796a6994f7b6d7" +
		"b8878e01081036b1e3038501474fe60a340a320a0369626312203822f32f21665363294f96edda15a7811a676c2ba9dd" +
		"ccec466364f10069827d1a090801180120012a0100"

	nonexistProofHex = "0a8c021289020a0160126b0a01501201501a0b0801180120012a03000202222b08011204040602201a2120798e2caa96" +
		"fdfba376ddeb47999954d2f47e65162264b0536ab5dff7fc0a2e07222908011225060a02209af37dd595a0190803b5e0" +
		"5aaef42ae3fad499e4fbe37f7cd31cadff22a9ee74201a96010a01721201721a0b0801180120012a03000202222b0801" +
		"1204020402201a2120a303930ca8831618ac7e4ddd10546cfc366fb730d6630c030a97226bbefc693522290801122504" +
		"06022035f8ea805390e084854f399b42ccdeaea33a1dedc115638ac48d0600637dba1f20222908011225060a02209af3" +
		"7dd595a0190803b5e05aaef42ae3fad499e4fbe37f7cd31cadff22a9ee74200a340a320a0369626312203822f32f2166" +
		"5363294f96edda15a7811a676c2ba9ddccec466364f10069827d1a090801180120012a0100"
)

func mustHex(s string) []byte {
	bz, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return bz
}

// The proofs ibc-go encodes decode, verify against the app hash, and encode
// back to the same bytes.
func TestMerkleProofIBCGoVectors(t *testing.T) {
	root := mustHex(merkleRoot)
	for _, tc := range []struct {
		name  string
		bz    []byte
		key   byte
		exist bool
	}{
		{"existence", mustHex(existProofHex), 0x32, true},
		{"non-existence", mustHex(nonexistProofHex), 0x60, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			proofs, err := ics23.UnmarshalMerkleProof(tc.bz)
			urequire.NoError(t, err)
			urequire.Equal(t, 2, len(proofs))

			var subroot []byte
			if tc.exist {
				ep := proofs[0].GetExist()
				urequire.True(t, ep != nil, "want an existence proof")
				urequire.NoError(t, ep.Verify(ics23.IavlSpec(), mustCalculate(t, ep), []byte{tc.key}, []byte{tc.key}))
				subroot = mustCalculate(t, ep)
			} else {
				np := proofs[0].GetNonexist()
				urequire.True(t, np != nil, "want a non-existence proof")
				var err error
				subroot, err = np.Calculate()
				urequire.NoError(t, err)
				urequire.NoError(t, np.Verify(ics23.IavlSpec(), subroot, []byte{tc.key}))
			}
			store := proofs[1].GetExist()
			urequire.True(t, store != nil, "want the store's existence proof")
			urequire.NoError(t, store.Verify(ics23.TendermintSpec(), root, []byte("ibc"), subroot))

			urequire.True(t, bytes.Equal(tc.bz, ics23.MarshalMerkleProof(proofs)), "re-encoding differs")
		})
	}
}

func mustCalculate(t *testing.T, ep *ics23.ExistenceProof) []byte {
	root, err := ep.Calculate()
	urequire.NoError(t, err)
	return root
}

// A proof built in Gno survives the round trip, nil pointers and empty
// fields included.
func TestMerkleProofRoundTrip(t *testing.T) {
	proofs := []ics23.CommitmentProof{
		ics23.CommitmentProof_Exist{Exist: &ics23.ExistenceProof{
			Key: []byte("k"), Value: []byte("v"),
			Leaf: &ics23.LeafOp{Hash: ics23.HashOp_SHA256, Length: ics23.LengthOp_VAR_PROTO, Prefix: []byte{0}},
			Path: []*ics23.InnerOp{{Hash: ics23.HashOp_SHA256, Prefix: []byte{1}}, {Suffix: []byte{2}}},
		}},
		ics23.CommitmentProof_Nonexist{Nonexist: &ics23.NonExistenceProof{
			Key:  []byte("m"),
			Left: &ics23.ExistenceProof{Key: []byte("l"), Leaf: &ics23.LeafOp{}},
		}},
	}
	bz := ics23.MarshalMerkleProof(proofs)
	got, err := ics23.UnmarshalMerkleProof(bz)
	urequire.NoError(t, err)
	urequire.True(t, bytes.Equal(bz, ics23.MarshalMerkleProof(got)), "re-encoding differs")

	ep := got[0].GetExist()
	urequire.Equal(t, "k", string(ep.Key))
	urequire.True(t, ep.Leaf.Length == ics23.LengthOp_VAR_PROTO, "leaf length op")
	urequire.Equal(t, 2, len(ep.Path))
	urequire.Equal(t, 2, int(ep.Path[1].Suffix[0]))
	np := got[1].GetNonexist()
	urequire.True(t, np.Right == nil, "right must stay nil")
	urequire.True(t, np.Left.Leaf != nil, "an empty leaf must survive")

	empty, err := ics23.UnmarshalMerkleProof(nil)
	urequire.NoError(t, err)
	urequire.Equal(t, 0, len(empty))
}

// cp wraps a CommitmentProof body as the MerkleProof's single proof.
func cp(body ...byte) []byte {
	return append([]byte{0x0a, byte(len(body))}, body...)
}

func TestMerkleProofMalformed(t *testing.T) {
	for _, tc := range []struct {
		name   string
		bz     []byte
		expErr string
	}{
		{"truncated length", []byte{0x0a, 0x05, 0x0a}, "beyond the message"},
		{"bad varint", []byte{0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01}, "bad varint"},
		{"field number zero", []byte{0x02, 0x00}, "bad field number"},
		{"proofs as varint", []byte{0x08, 0x01}, "wire type 0"},
		{"group wire type", []byte{0x13}, "wire type 3"},
		{"empty commitment proof", cp(), "empty commitment proof"},
		{"batch proof", cp(0x1a, 0x00), "batch"},
		{"compressed batch proof", cp(0x22, 0x00), "batch"},
		{"exist and nonexist", cp(0x0a, 0x00, 0x12, 0x00), "more than one proof"},
		{"exist twice", cp(0x0a, 0x00, 0x0a, 0x00), "more than one proof"},
		{"key twice", cp(0x0a, 0x06, 0x0a, 0x01, 0x61, 0x0a, 0x01, 0x62), "field 1 is set twice"},
		{"leaf twice", cp(0x0a, 0x04, 0x1a, 0x00, 0x1a, 0x00), "field 3 is set twice"},
		{"leaf hash as bytes", cp(0x0a, 0x04, 0x1a, 0x02, 0x0a, 0x00), "field 1 has wire type 2"},
		{"leaf hash twice", cp(0x0a, 0x06, 0x1a, 0x04, 0x08, 0x01, 0x08, 0x01), "field 1 is set twice"},
		{"leaf enum out of range", cp(0x0a, 0x09, 0x1a, 0x07, 0x08, 0x80, 0x80, 0x80, 0x80, 0x10, 0x00), "out of range"},
		{"inner prefix as varint", cp(0x0a, 0x04, 0x22, 0x02, 0x10, 0x01), "field 2 has wire type 0"},
		{"nonexist left twice", cp(0x12, 0x04, 0x12, 0x00, 0x12, 0x00), "field 2 is set twice"},
		{"truncated fixed64", cp(0x0a, 0x03, 0x29, 0x00, 0x00), "truncated field"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ics23.UnmarshalMerkleProof(tc.bz)
			urequire.Error(t, err)
			if !strings.Contains(err.Error(), tc.expErr) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.expErr)
			}
		})
	}
}

// Unknown fields are skipped, as protobuf does, at every level.
func TestMerkleProofUnknownFields(t *testing.T) {
	bz := []byte{
		0x10, 0x07, // MerkleProof field 2 (varint)
		0x0a, 0x10, // proofs[0]
		0x2a, 0x00, // CommitmentProof field 5 (empty bytes)
		0x0a, 0x0c, // exist
		0x0a, 0x01, 0x6b, // key "k"
		0x2d, 0x01, 0x02, 0x03, 0x04, // ExistenceProof field 5 (fixed32)
		0x1a, 0x02, 0x30, 0x05, // leaf with field 6 (varint)
	}
	proofs, err := ics23.UnmarshalMerkleProof(bz)
	urequire.NoError(t, err)
	urequire.Equal(t, 1, len(proofs))
	ep := proofs[0].GetExist()
	urequire.Equal(t, "k", string(ep.Key))
	urequire.True(t, ep.Leaf != nil, "leaf must be set")
}
