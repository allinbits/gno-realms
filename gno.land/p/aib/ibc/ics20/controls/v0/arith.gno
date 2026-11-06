package controls

import (
	"math"
	"math/overflow"
	"strconv"
)

// Arithmetic of the controls. Every amount, total and meter level is a
// uint256 (the range of an ICS20 amount on the wire, and of a grc20 v1
// voucher), and every aggregate goes through one of these, by what reads it:
//
//   - checkedAdd for a liability or payment total a check reads: the
//     operation that would pass 2^256 - 1 is refused before anything changes
//     (a credit, a loss recorded by decision, a sweep payment);
//   - mustAdd and mustSub where an earlier check bounds the result (a move
//     between totals whose sum was checked, a payment within what is owed, a
//     resolution bounded by its losses): an overflow or a negative result
//     there is a broken invariant and aborts the transaction;
//   - boundAdd for a sum only ever used as the upper bound of what is reserved
//     or booked (Reserved, booked, a route's loss totals): saturating at the
//     maximum can only make the check it feeds refuse more;
//   - statAdd for a statistic no check reads (credited, paid, fees, sent,
//     refunded...): it saturates, and the JSON shows the maximum;
//   - sub0 for a reading that floors at zero (the free lock, a supply counted
//     from before the controls).
//
// On an Ethereum route every packet carries at most 2^96 - 1 (abi.MaxAmount),
// so no total of this package reaches 2^256 in any chain's lifetime; the
// rules above only say what happens if one did. Counters that grow by one per
// transaction (queue and refund sequences, authorization ids, record counts)
// stay int64.

// maxAmount is the largest amount: every saturating sum stops there.
const maxAmount uint256 = math.MaxUint256

// checkedAdd is a + b, and whether it fits a uint256.
func checkedAdd(a, b uint256) (uint256, bool) { return overflow.Addu256(a, b) }

// mustAdd is a + b where a check bounded the sum.
func mustAdd(a, b uint256) uint256 {
	s, ok := overflow.Addu256(a, b)
	if !ok {
		panic("controls: an aggregate would overflow")
	}
	return s
}

// mustSub is a - b where an invariant keeps b within a.
func mustSub(a, b uint256) uint256 {
	if b > a {
		panic("controls: a counter went negative")
	}
	return a - b
}

// sub0 is a - b, or 0 when b is more than a.
func sub0(a, b uint256) uint256 {
	if b >= a {
		return 0
	}
	return a - b
}

// boundAdd is a + b, saturating at the maximum.
func boundAdd(a, b uint256) uint256 {
	s, ok := overflow.Addu256(a, b)
	if !ok {
		return maxAmount
	}
	return s
}

// statAdd is boundAdd for a statistic.
func statAdd(a, b uint256) uint256 { return boundAdd(a, b) }

// u is an amount in decimal digits (ufmt takes no uint256).
func u(v uint256) string { return strconv.FormatUint256(v, 10) }

// qu is an amount as a JSON string: amounts are quoted in every JSON this
// package renders, so a 256-bit value survives a reader that parses numbers
// as doubles.
func qu(v uint256) string { return "\"" + u(v) + "\"" }
