package arc

import (
	"bytes"
	"crypto/modexp"
)

// Arc's consensus layer drops a registered validator whose public key does
// not decode to an Ed25519 point (arc-node crates/eth-engine/src/abi_utils.rs,
// try_decode_validator: ed25519_consensus::VerificationKey::try_from, which
// is curve25519-dalek's CompressedEdwardsY::decompress), and the registry
// only checks a key's length. The client drops the same keys: one it kept
// could never sign (Go's ed25519.Verify refuses it) but would count in the
// set's total power.
//
// decompress accepts y as encoded, reduced mod p (ZIP-215 allows
// non-canonical encodings), and succeeds when x^2 = u/v has a root, with
// u = y^2 - 1 and v = d*y^2 + 1: when u = 0, or v != 0 and u/v is a square.
// The sign bit picks the root and never fails. By Euler's criterion that is
// legendre(u) * legendre(v) = 1, and legendre(4v) = legendre(v); 4*d*y^2 is
// (d+y^2)^2 - (d-y^2)^2, so everything reduces to squarings, additions and
// exponentiations mod p, which crypto/modexp computes.

// fieldP is 2^255 - 19, big-endian.
var fieldP = []byte{
	0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xed,
}

// legendreExp is (p-1)/2, big-endian.
var legendreExp = []byte{
	0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf6,
}

// curveD is the Edwards constant d = -121665/121666 mod p, big-endian.
var curveD = []byte{
	0x52, 0x03, 0x6c, 0xee, 0x2b, 0x6f, 0xfe, 0x73, 0x8c, 0xc7, 0x40, 0x79, 0x77, 0x79, 0xe8, 0x98,
	0x00, 0x70, 0x0a, 0x4d, 0x41, 0x41, 0xd8, 0xab, 0x75, 0xeb, 0x4d, 0xca, 0x13, 0x59, 0x78, 0xa3,
}

var (
	two  = []byte{2}
	one  = []byte{1}
	four = []byte{4}
)

func reduce(x []byte) []byte { return modexp.ModExp(x, one, fieldP) }

// addMod is a+b mod p, for a, b below p.
func addMod(a, b []byte) []byte {
	sum := make([]byte, 33)
	carry := 0
	for i := 31; i >= 0; i-- {
		s := int(a[i]) + int(b[i]) + carry
		sum[i+1] = byte(s)
		carry = s >> 8
	}
	sum[0] = byte(carry)
	return reduce(sum)
}

// negMod is -a mod p, for a below p.
func negMod(a []byte) []byte {
	if isZero(a) {
		return make([]byte, 32)
	}
	out := make([]byte, 32)
	borrow := 0
	for i := 31; i >= 0; i-- {
		d := int(fieldP[i]) - int(a[i]) - borrow
		borrow = 0
		if d < 0 {
			d += 256
			borrow = 1
		}
		out[i] = byte(d)
	}
	return out
}

func isZero(a []byte) bool { return bytes.Equal(a, make([]byte, len(a))) }

// legendre is a^((p-1)/2) mod p: 1 for a nonzero square, p-1 for a
// non-square, 0 for zero.
func legendre(a []byte) []byte { return modexp.ModExp(a, legendreExp, fieldP) }

// isEdwardsPoint reports whether the 32-byte key decodes to a point.
func isEdwardsPoint(key []byte) bool {
	// y: little-endian, the top bit (the sign of x) cleared, reduced mod p.
	be := make([]byte, 32)
	for i := range key {
		be[31-i] = key[i]
	}
	be[0] &= 0x7f
	y := reduce(be)
	y2 := modexp.ModExp(y, two, fieldP)
	pad := make([]byte, 31)
	u := addMod(y2, negMod(append(cloneBytes(pad), 1)))
	if isZero(u) {
		return true
	}
	// 4v = (d+y^2)^2 - (d-y^2)^2 + 4
	plus := modexp.ModExp(addMod(curveD, y2), two, fieldP)
	minus := modexp.ModExp(addMod(curveD, negMod(y2)), two, fieldP)
	v4 := addMod(addMod(plus, negMod(minus)), append(cloneBytes(pad), four...))
	if isZero(v4) {
		return false
	}
	return bytes.Equal(legendre(u), legendre(v4))
}
