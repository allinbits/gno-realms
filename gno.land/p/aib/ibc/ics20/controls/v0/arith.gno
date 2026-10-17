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
//     refunded...): it saturates, and the JSON shows the maximum;
//   - a wide counter for the open sends' remainders and the refunds owed
//     (InFlight, Returning, QueuedRefunds, Parked, ProvenOwed): each can
//     genuinely pass 2^63 (coins escrowed or burned by an open send can be
//     paid out by a claim and sent again while it is open), and no send,
//     acknowledgement, timeout, settlement or proof may be refused for it.
//     It is kept exact beyond int64 (wide), and its int64 view saturates; the
//     checks that read it bound what is reserved, so a saturated view only
//     makes them refuse more.
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

// wideBase is the base of a wide counter's low limb: 2^62.
const wideBase = int64(1) << 62

// wide is an exact non-negative counter beyond int64: hi * 2^62 + lo, lo in
// [0, 2^62).
type wide struct{ hi, lo int64 }

func (w *wide) add(x int64) {
	if x < 0 {
		panic("controls: a negative wide addition")
	}
	w.hi += x / wideBase
	w.lo += x % wideBase
	if w.lo >= wideBase {
		w.lo -= wideBase
		w.hi++
	}
}

func (w *wide) sub(x int64) {
	if x < 0 {
		panic("controls: a negative wide subtraction")
	}
	w.hi -= x / wideBase
	w.lo -= x % wideBase
	if w.lo < 0 {
		w.lo += wideBase
		w.hi--
	}
	if w.hi < 0 {
		panic("controls: a wide counter went negative")
	}
}

// sat is the counter as an int64, saturating at the int64 maximum.
func (w wide) sat() int64 {
	if w.hi >= 2 {
		return maxInt64
	}
	return w.hi*wideBase + w.lo
}

// minusSat is the counter less x (at most the counter), as a saturated int64.
func (w wide) minusSat(x int64) int64 {
	w.sub(x)
	return w.sat()
}
