package controls

// Checked arithmetic of the controls. Every int64 aggregate goes through one
// of these, by what reads it:
//
//   - checkedAdd for a liability, reservation or loss total a check reads:
//     the operation that would overflow it is refused before anything changes
//     (a send, a credit, a loss, a settlement);
//   - mustAdd where an earlier check bounds the sum (a move between totals
//     whose sum was checked, a resolution bounded by its losses): an overflow
//     there is a broken invariant and aborts;
//   - boundAdd for a sum only ever used as the upper bound of what is reserved
//     or booked (Reserved, booked, the unpaid authorizations): saturating at
//     the int64 maximum can only make the check it feeds refuse more;
//   - statAdd for a statistic no check reads (credited, paid, fees, sent,
//     refunded...): it saturates, and the JSON shows the maximum.
//
// Counters that grow by one per transaction (queue and refund sequences,
// recapitalization ids, open-record counts) cannot reach 2^63.

// checkedAdd is a + b for non-negative terms, and whether it fits an int64.
func checkedAdd(a, b int64) (int64, bool) {
	if a < 0 || b < 0 || b > maxInt64-a {
		return 0, false
	}
	return a + b, true
}

// mustAdd is a + b where a check bounded the sum.
func mustAdd(a, b int64) int64 {
	s, ok := checkedAdd(a, b)
	if !ok {
		panic("controls: an aggregate would overflow")
	}
	return s
}

// boundAdd is a + b for non-negative terms, saturating at the int64 maximum.
func boundAdd(a, b int64) int64 {
	if b > maxInt64-a {
		return maxInt64
	}
	return a + b
}

// statAdd is boundAdd for a statistic.
func statAdd(a, b int64) int64 { return boundAdd(a, b) }
