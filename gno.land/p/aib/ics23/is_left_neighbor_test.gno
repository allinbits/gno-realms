package ics23_test

import (
	"testing"

	"gno.land/p/aib/ics23"
	"gno.land/p/nt/uassert/v0"
)

func TestIsLeftNeighbor_RejectsMalformedInput(t *testing.T) {
	spec := ics23.IavlSpec().InnerSpec
	validOp := func() *ics23.InnerOp {
		return &ics23.InnerOp{Prefix: []byte("aaaa"), Suffix: make([]byte, 33)}
	}
	convergingOp := &ics23.InnerOp{Prefix: []byte("aaaa"), Suffix: make([]byte, 33)}
	malformedOp := func() *ics23.InnerOp {
		return &ics23.InnerOp{Prefix: make([]byte, 100), Suffix: nil}
	}

	cases := []struct {
		name  string
		left  []*ics23.InnerOp
		right []*ics23.InnerOp
	}{
		{"empty left path", nil, []*ics23.InnerOp{validOp()}},
		{"empty right path", []*ics23.InnerOp{validOp()}, nil},
		{"common suffix exhausted", []*ics23.InnerOp{convergingOp}, []*ics23.InnerOp{convergingOp}},
		{"malformed left prefix", []*ics23.InnerOp{malformedOp()}, []*ics23.InnerOp{validOp()}},
		{"malformed right prefix", []*ics23.InnerOp{validOp()}, []*ics23.InnerOp{malformedOp()}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("IsLeftNeighbor must not panic, got %v", r)
				}
			}()
			ok, _ := ics23.IsLeftNeighbor(spec, tc.left, tc.right)
			uassert.False(t, ok, "expected isNeighbor=false")
		})
	}
}
