package ics23_test

import (
	"encoding/hex"
	"testing"

	"gno.land/p/aib/ics23"
	"gno.land/p/nt/uassert/v0"
)

func TestProofSpecEqual(t *testing.T) {
	newLeaf := func() *ics23.LeafOp {
		return &ics23.LeafOp{
			Prefix:       []byte{0},
			PrehashKey:   ics23.HashOp_NO_HASH,
			Hash:         ics23.HashOp_SHA256,
			PrehashValue: ics23.HashOp_SHA256,
			Length:       ics23.LengthOp_VAR_PROTO,
		}
	}
	newInner := func() *ics23.InnerSpec {
		return &ics23.InnerSpec{
			ChildOrder:      []int32{0, 1},
			MinPrefixLength: 4,
			MaxPrefixLength: 12,
			ChildSize:       33,
			EmptyChild:      nil,
			Hash:            ics23.HashOp_SHA256,
		}
	}
	newSpec := func() *ics23.ProofSpec {
		return &ics23.ProofSpec{
			LeafSpec:                   newLeaf(),
			InnerSpec:                  newInner(),
			MaxDepth:                   0,
			MinDepth:                   0,
			PrehashKeyBeforeComparison: false,
		}
	}

	testCases := []struct {
		name     string
		malleate func(a, b *ics23.ProofSpec)
		expEqual bool
	}{
		{"equal — same fresh spec", func(a, b *ics23.ProofSpec) {}, true},
		{"equal — same as well-known IavlSpec", func(a, b *ics23.ProofSpec) {
			*a = *ics23.IavlSpec()
			*b = *ics23.IavlSpec()
		}, true},
		{"differ — MaxDepth", func(a, b *ics23.ProofSpec) { b.MaxDepth = 10 }, false},
		{"differ — MinDepth", func(a, b *ics23.ProofSpec) { b.MinDepth = 1 }, false},
		{"differ — PrehashKeyBeforeComparison", func(a, b *ics23.ProofSpec) { b.PrehashKeyBeforeComparison = true }, false},
		{"differ — LeafSpec.Hash", func(a, b *ics23.ProofSpec) { b.LeafSpec.Hash = ics23.HashOp_NO_HASH }, false},
		{"differ — LeafSpec.PrehashKey", func(a, b *ics23.ProofSpec) { b.LeafSpec.PrehashKey = ics23.HashOp_SHA256 }, false},
		{"differ — LeafSpec.PrehashValue", func(a, b *ics23.ProofSpec) { b.LeafSpec.PrehashValue = ics23.HashOp_NO_HASH }, false},
		{"differ — LeafSpec.Length", func(a, b *ics23.ProofSpec) { b.LeafSpec.Length = ics23.LengthOp_NO_PREFIX }, false},
		{"differ — LeafSpec.Prefix", func(a, b *ics23.ProofSpec) { b.LeafSpec.Prefix = []byte{1} }, false},
		{"differ — LeafSpec nil vs non-nil", func(a, b *ics23.ProofSpec) { b.LeafSpec = nil }, false},
		{"differ — InnerSpec.ChildSize", func(a, b *ics23.ProofSpec) { b.InnerSpec.ChildSize = 32 }, false},
		{"differ — InnerSpec.MinPrefixLength", func(a, b *ics23.ProofSpec) { b.InnerSpec.MinPrefixLength = 1 }, false},
		{"differ — InnerSpec.MaxPrefixLength", func(a, b *ics23.ProofSpec) { b.InnerSpec.MaxPrefixLength = 99 }, false},
		{"differ — InnerSpec.Hash", func(a, b *ics23.ProofSpec) { b.InnerSpec.Hash = ics23.HashOp_NO_HASH }, false},
		{"differ — InnerSpec.ChildOrder length", func(a, b *ics23.ProofSpec) { b.InnerSpec.ChildOrder = []int32{0, 1, 2} }, false},
		{"differ — InnerSpec.ChildOrder content", func(a, b *ics23.ProofSpec) { b.InnerSpec.ChildOrder = []int32{1, 0} }, false},
		{"differ — InnerSpec.EmptyChild", func(a, b *ics23.ProofSpec) { b.InnerSpec.EmptyChild = []byte{0, 0, 0} }, false},
		{"differ — InnerSpec nil vs non-nil", func(a, b *ics23.ProofSpec) { b.InnerSpec = nil }, false},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			a, b := newSpec(), newSpec()
			tc.malleate(a, b)
			uassert.Equal(t, tc.expEqual, a.Equal(b), "a.Equal(b)")
			// Equal must be symmetric.
			uassert.Equal(t, tc.expEqual, b.Equal(a), "b.Equal(a)")
		})
	}
}

func TestProofSpecEqualNil(t *testing.T) {
	spec := ics23.IavlSpec()

	var nilSpec *ics23.ProofSpec
	uassert.True(t, nilSpec.Equal(nil), "nil.Equal(nil) must be true")
	uassert.False(t, spec.Equal(nil), "non-nil.Equal(nil) must be false")
	uassert.False(t, nilSpec.Equal(spec), "nil.Equal(non-nil) must be false")
}

func TestLeafOpEqual(t *testing.T) {
	var nilOp *ics23.LeafOp
	uassert.True(t, nilOp.Equal(nil))

	a := &ics23.LeafOp{Hash: ics23.HashOp_SHA256, Prefix: []byte{0x01}}
	b := &ics23.LeafOp{Hash: ics23.HashOp_SHA256, Prefix: []byte{0x01}}
	uassert.True(t, a.Equal(b))
	uassert.False(t, a.Equal(nil))

	b.Prefix = []byte{0x02}
	uassert.False(t, a.Equal(b))
}

func TestInnerSpecEqual(t *testing.T) {
	var nilSpec *ics23.InnerSpec
	uassert.True(t, nilSpec.Equal(nil))

	a := &ics23.InnerSpec{ChildOrder: []int32{0, 1}, ChildSize: 33, Hash: ics23.HashOp_SHA256}
	b := &ics23.InnerSpec{ChildOrder: []int32{0, 1}, ChildSize: 33, Hash: ics23.HashOp_SHA256}
	uassert.True(t, a.Equal(b))
	uassert.False(t, a.Equal(nil))

	b.ChildSize = 32
	uassert.False(t, a.Equal(b))
}

func TestLeafOpProtoMarshal(t *testing.T) {
	t.Run("nil receiver returns nil", func(t *testing.T) {
		var nilLeaf *ics23.LeafOp
		uassert.Equal(t, 0, len(nilLeaf.ProtoMarshal()))
	})

	t.Run("matches expected wire format for IavlSpec.LeafSpec", func(t *testing.T) {
		bz := ics23.IavlSpec().LeafSpec.ProtoMarshal()
		// Field 1 (Hash=SHA256=1):     08 01
		// Field 2 (PrehashKey=0):      omitted
		// Field 3 (PrehashValue=1):    18 01
		// Field 4 (Length=VAR_PROTO=1):20 01
		// Field 5 (Prefix=[0x00]):     2a 01 00
		uassert.Equal(t, "0801180120012a0100", hex.EncodeToString(bz))
	})
}

func TestInnerSpecProtoMarshal(t *testing.T) {
	t.Run("nil receiver returns nil", func(t *testing.T) {
		var nilInner *ics23.InnerSpec
		uassert.Equal(t, 0, len(nilInner.ProtoMarshal()))
	})

	t.Run("matches expected wire format for IavlSpec.InnerSpec", func(t *testing.T) {
		bz := ics23.IavlSpec().InnerSpec.ProtoMarshal()
		// Field 1 (ChildOrder=[0,1] packed): 0a 02 00 01
		// Field 2 (ChildSize=33):            10 21
		// Field 3 (MinPrefixLength=4):       18 04
		// Field 4 (MaxPrefixLength=12):      20 0c
		// Field 5 (EmptyChild=nil):          omitted
		// Field 6 (Hash=SHA256=1):           30 01
		uassert.Equal(t, "0a02000110211804200c3001", hex.EncodeToString(bz))
	})
}

func TestProofSpecProtoMarshal(t *testing.T) {
	t.Run("nil receiver returns nil", func(t *testing.T) {
		var nilSpec *ics23.ProofSpec
		uassert.Equal(t, 0, len(nilSpec.ProtoMarshal()))
	})

	t.Run("matches expected wire format for IavlSpec", func(t *testing.T) {
		bz := ics23.IavlSpec().ProtoMarshal()
		// Field 1 (LeafSpec, len=9):  0a 09 <leaf bytes>
		// Field 2 (InnerSpec, len=12):12 0c <inner bytes>
		// Fields 3,4,5: omitted (zero defaults)
		want := "0a090801180120012a0100" + "120c0a02000110211804200c3001"
		uassert.Equal(t, want, hex.EncodeToString(bz))
	})

	t.Run("optional fields are emitted when set", func(t *testing.T) {
		spec := &ics23.ProofSpec{
			MaxDepth:                   8,
			MinDepth:                   1,
			PrehashKeyBeforeComparison: true,
		}
		bz := spec.ProtoMarshal()
		// Field 3 (MaxDepth=8):                         18 08
		// Field 4 (MinDepth=1):                         20 01
		// Field 5 (PrehashKeyBeforeComparison=true):    28 01
		uassert.Equal(t, "180820012801", hex.EncodeToString(bz))
	})
}
