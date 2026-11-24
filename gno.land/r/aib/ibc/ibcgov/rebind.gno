package ibcgov

import (
	"chain"
	"encoding/binary"
	"strconv"
	"strings"
)

// Burned numbers and Rebind (ADR 0004, "Burned numbers").
//
// IBCAdmin applies a kind 1's tombstones when the cancel arrives, clamped to
// its horizon (its last recorded number plus its window, 64), and answers a
// decision recorded at a tombstoned number with status 6, cancelled, as it
// answers a re-delivery of one. A cancel this realm never sent (a packet a
// compromised verifier let through) burns at most those 64 numbers past
// IBCAdmin's head: the decisions bound to them are recorded cancelled and
// never execute, though governance approved them.
//
// This realm tells the two apart: a number one of its own kind 1s named in
// that epoch (every kind 1 it dispatched, indexed in cancels when it is
// bound) is cancelled, final; any other number acknowledged 6 is burned.
// Anyone may Rebind the burned dispatches of the current epoch: each is
// bound again, in its original order, to the epoch's next numbers, with the
// same kind and params in a fresh envelope, and sent through bind and send
// like any dispatch, under its one-time dispatch authorization. No vote is
// needed: governance approved those decisions already, and the copy says
// nothing the original did not. The burned number stays burned and points
// at its copy (reboundTo), the copy back at it (reboundFrom).
//
// A kind 10 whose new router client a burned kind 6 op 1 enrols is not
// rebound: IBCAdmin keeps such a kind 10 pending (its execution reverts
// while the client is not enrolled), so rebinding the kind 6 is enough, and
// the original kind 10 executes once the kind 6's copy has.
//
// A burned dispatch of a past epoch is not rebindable: the new epoch's
// governance decides it again. An attacker who keeps forging cancels burns
// each copy too; that is the emergency recovery's case (ADR pr6375 §7.12).

// maxRebind bounds the numbers a Rebind call reads, and so the dispatches it
// binds.
const maxRebind = 64

// span is a range of cancelled numbers, to its last, and by, the highest
// seq of the kind 1s that named any of it.
type span struct{ to, by uint64 }

// cancelledBy reports whether a kind 1 this realm dispatched in epoch e
// names seq, and the highest seq of the kind 1s whose ranges were merged
// into the one that covers it (an upper bound on the last one naming seq:
// see grantStands). cancels holds every such range, merged where they
// overlap into disjoint ones, so one lookup answers: the last range starting
// at or before seq.
func cancelledBy(g *routeGov, e uint32, seq uint64) (bool, uint64) {
	var sp *span
	g.cancels.ReverseIterate(epochKey(e)+"/", dispatchKey(e, seq)+"\x00", func(_ string, v any) bool {
		sp = v.(*span)
		return true
	})
	if sp == nil || sp.to < seq {
		return false, 0
	}
	return true, sp.by
}

// cancelledHere reports whether a kind 1 this realm dispatched in epoch e
// names seq.
func cancelledHere(g *routeGov, e uint32, seq uint64) bool {
	covered, _ := cancelledBy(g, e, seq)
	return covered
}

// grantStands reports whether d holds a retransmit authorization no kind 1
// bound since voids: one granted before a cancel of its number never checked
// the tombstone (IBCAdmin drops one past its horizon), so only one decided
// after the cancel lets that number be re-sent. Lazy, one lookup: a kind 1
// bound after the grant has a seq above the epoch's last seq then
// (grantAt). The merged range's by may come from another kind 1 than the
// one naming d (ranges merge where they overlap), so a grant can be voided
// by a later cancel of a neighbouring number: it fails closed, and
// governance decides the grant again.
func grantStands(g *routeGov, d *dispatch) bool {
	if !d.retransmit {
		return false
	}
	covered, by := cancelledBy(g, d.epoch, d.seq)
	return !covered || by <= d.grantAt
}

// addCancelled records the range [from, to] of epoch e as cancelled by the
// kind 1 at seq by, merging it with the ranges it overlaps. A call removes
// every range it absorbs, which can be many, but each stored range is
// inserted by one range of a kind 1 (at most 14 a cancel, every one a
// governed decision, or Rebind's copy of one, whose ranges overlap what its
// original stored) and removed at most once: the merges are paid for by the
// inserts that made the ranges, and their number is bounded by the cancels
// governance decided in the epoch. Ranges merge only where they overlap,
// not where they touch, so by stays close to the cancels naming a number.
func addCancelled(g *routeGov, e uint32, from, to, by uint64) {
	g.cancels.ReverseIterate(epochKey(e)+"/", dispatchKey(e, from)+"\x00", func(k string, v any) bool {
		if sp := v.(*span); sp.to >= from {
			_, s, _ := strings.Cut(k, "/")
			from, _ = strconv.ParseUint(s, 10, 64)
			if sp.to > to {
				to = sp.to
			}
			if sp.by > by {
				by = sp.by
			}
		}
		return true
	})
	var absorbed []string
	g.cancels.Iterate(dispatchKey(e, from), epochKey(e)+"0", func(k string, v any) bool { // '0' follows '/'
		_, s, _ := strings.Cut(k, "/")
		if start, _ := strconv.ParseUint(s, 10, 64); start > to {
			return true
		}
		absorbed = append(absorbed, k)
		sp := v.(*span)
		if sp.to > to {
			to = sp.to
		}
		if sp.by > by {
			by = sp.by
		}
		return false
	})
	for _, k := range absorbed {
		g.cancels.Remove(k)
	}
	g.cancels.Set(dispatchKey(e, from), &span{to: to, by: by})
}

// indexDispatch records a newly bound kind 1's ranges (cancelledHere,
// grantStands). The params are this realm's own encoding.
func indexDispatch(g *routeGov, d *dispatch) {
	params := d.body[envelopeHeader:]
	if d.kind != KindCancel {
		return
	}
	n, ok := abiWord(params, 1)
	for i := uint64(0); ok && i < n && i < maxCancelRanges; i++ {
		from, ok1 := abiWord(params, int(2+2*i))
		to, ok2 := abiWord(params, int(3+2*i))
		if ok1 && ok2 && from <= to {
			addCancelled(g, d.epoch, from, to, d.seq)
		}
	}
}

// abiWord is the low 64 bits of params' i-th 32-byte word.
func abiWord(p []byte, i int) (uint64, bool) {
	if i < 0 || len(p) < 32*(i+1) {
		return 0, false
	}
	return binary.BigEndian.Uint64(p[32*i+24 : 32*i+32]), true
}

// rebindable is why d cannot be rebound now, or "".
func rebindable(g *routeGov, d *dispatch) string {
	what := "decision " + u64s(d.seq)
	switch {
	case d.reboundTo != 0:
		return what + " is rebound already, as seq " + u64s(d.reboundTo)
	case cancelledHere(g, d.epoch, d.seq):
		return what + " is cancelled by a cancel of this realm"
	case d.burned:
		return ""
	}
	return what + " is not burned (" + d.event + ")"
}

// Rebind binds every burned dispatch of route's current epoch e numbered
// from to to (inclusive, at most 64 numbers) to the epoch's next numbers, in
// their original order, with the same kind and params in fresh envelopes,
// and sends them (see above). Anyone may call it; it returns the numbers it
// bound. Refused for a past epoch, an empty or oversized range, and a
// range holding no rebindable dispatch; dispatches in the range that are not
// rebindable (not burned, cancelled by this realm, rebound already) are
// left as they are. Every check of a dispatch applies (bind): a paused core
// or an unusable epoch client refuses the whole call, and a copy that would
// lie more than GovWindow past the known head stops it there (checkAhead),
// keeping what it bound, or refuses it if it bound nothing.
func Rebind(cur realm, route string, e uint32, from, to uint64) []uint64 {
	g := mustEnrolledGov(route)
	if e != g.epoch {
		panic("ibcgov: epoch " + strconv.FormatUint(uint64(e), 10) + " is not the current one: a past epoch's decisions are decided again")
	}
	if from < 1 || to < from {
		panic("ibcgov: an empty range: " + u64s(from) + "-" + u64s(to))
	}
	if to-from >= maxRebind {
		panic("ibcgov: rebind at most " + strconv.Itoa(maxRebind) + " numbers a call")
	}
	var olds []*dispatch
	g.dispatches.Iterate(dispatchKey(e, from), dispatchKey(e, to)+"\x00", func(_ string, v any) bool {
		olds = append(olds, v.(*dispatch))
		return false
	})
	var out []uint64
	refusal := "no dispatched decision in " + u64s(from) + "-" + u64s(to)
	for _, d := range olds {
		if why := rebindable(g, d); why != "" {
			if len(out) == 0 {
				refusal = why
			}
			continue
		}
		// The copies obey the same bound as any dispatch: past it, the call
		// stops, and the rest wait for a later one.
		if ahead := checkAhead(g, d.kind); ahead != "" {
			if len(out) == 0 {
				panic("ibcgov: " + ahead)
			}
			break
		}
		seq, why := bind(cur, g, d.decision, d.kind, d.body[envelopeHeader:])
		if why != "" {
			panic("ibcgov: " + why)
		}
		d.reboundTo = seq
		d.event += "; rebound as seq " + u64s(seq)
		c := dispatchOf(g, e, seq)
		c.reboundFrom = d.seq
		chain.Emit("GovRebind", "route", g.key, "epoch", strconv.FormatUint(uint64(e), 10), "seq", u64s(d.seq), "to", u64s(seq),
			"kind", strconv.Itoa(int(d.kind)))
		out = append(out, seq)
	}
	if len(out) == 0 {
		panic("ibcgov: nothing to rebind: " + refusal)
	}
	return out
}

// DispatchRebind says whether route's dispatch (e, seq) is burned, the
// number it was rebound to (0 if none), and the number it is a copy of (0
// if none).
func DispatchRebind(route string, e uint32, seq uint64) (burned bool, reboundTo, reboundFrom uint64) {
	if d := routeDispatch(route, e, seq); d != nil {
		return d.burned, d.reboundTo, d.reboundFrom
	}
	return false, 0, 0
}
