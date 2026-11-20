package arc

import (
	"encoding/hex"
	"testing"
)

// Vectors from filippo.io/edwards25519 (Point.SetBytes) on canonical y:
// y = 3, 4, 5, 6, 9 decode, y = 2, 7, 8 do not.
func TestIsEdwardsPoint(t *testing.T) {
	key := func(y byte, sign bool) []byte {
		k := make([]byte, 32)
		k[0] = y
		if sign {
			k[31] = 0x80
		}
		return k
	}
	for _, y := range []byte{3, 4, 5, 6, 9} {
		if !isEdwardsPoint(key(y, false)) || !isEdwardsPoint(key(y, true)) {
			t.Errorf("y=%d should decode", y)
		}
	}
	for _, y := range []byte{2, 7, 8} {
		if isEdwardsPoint(key(y, false)) {
			t.Errorf("y=%d should not decode", y)
		}
	}
	// y = 1 (u = 0): the identity, x = 0.
	if !isEdwardsPoint(key(1, false)) {
		t.Error("y=1 should decode")
	}
	// The Ed25519 base point.
	b, _ := hex.DecodeString("5866666666666666666666666666666666666666666666666666666666666666")
	if !isEdwardsPoint(b) {
		t.Error("the base point should decode")
	}
}

func TestValidatorSetRefusesNonPoints(t *testing.T) {
	bad := make([]byte, 32)
	bad[0] = 2
	if _, err := NewValidatorSet([][]byte{bad}, []uint64{1}); err == nil {
		t.Fatal("a key that is no point was accepted")
	}
}

func TestMulGreater(t *testing.T) {
	max := ^uint64(0)
	if !mulGreater(max, max, max, max-1) || mulGreater(max, 2, 2, max) || !mulGreater(1<<62, 1<<32, (1<<62)-1, 1<<32) {
		t.Fatal("mulGreater")
	}
}
