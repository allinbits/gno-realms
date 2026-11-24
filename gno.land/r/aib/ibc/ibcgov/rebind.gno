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
// One more dispatch depends on a burned one: a kind 10 whose new router
// client a kind 6 op 1 enrols. IBCAdmin spends that kind 10 at execution
// when the client is unknown there, which no acknowledgement reports (the
// kind 10 was acknowledged when it was recorded). So a kind 10 Ethereum
// holds (acknowledged recorded, buffered, duplicate or spent) is rebindable
// too when a kind 6 op 1 of its epoch, dispatched before it and enrolling
// its new client, was burned and already rebound past it: the copy then
// follows the kind 6's copy, so it executes after the client exists. If the
// original kind 10 executes all the same (its kind 6's copy executed first),
// the epoch switch abandons the copy; if not, the copy is the one to run.
// gno.land cannot tell that spend from a kind 10 still pending there, and
// does not need to: either way at most one of the two executes.
//
// A burned dispatch of a past epoch is not rebindable: the new epoch's
// governance decides it again. An attacker who keeps forging cancels burns
// each copy too; that is the emergency recovery's case (ADR pr6375 §7.12).

// maxRebind bounds the numbers a Rebind call reads, and so the dispatches it
// binds.
const maxRebind = 64

// cancelledHere reports whether a kind 1 this realm dispatched in epoch e
// names seq. cancels holds every such range, merged into disjoint ones, so
// one lookup answers: the last range starting at or before seq.
func cancelledHere(g *routeGov, e uint32, seq uint64) bool {
	covered := false
	g.cancels.ReverseIterate(epochKey(e)+"/", dispatchKey(e, seq)+"\x00", func(_ string, v any) bool {
		covered = v.(uint64) >= seq
		return true
	})
	return covered
}

// addCancelled records the range [from, to] of epoch e as cancelled here,
// merging it with the ranges it touches. Each range is merged into another
// once, so the merges are paid for by the inserts that made them.
func addCancelled(g *routeGov, e uint32, from, to uint64) {
	g.cancels.ReverseIterate(epochKey(e)+"/", dispatchKey(e, from)+"\x00", func(k string, v any) bool {
		if hi := v.(uint64); hi+1 >= from {
			_, s, _ := strings.Cut(k, "/")
			from, _ = strconv.ParseUint(s, 10, 64)
			if hi > to {
				to = hi
			}
		}
		return true
	})
	var absorbed []string
	g.cancels.Iterate(dispatchKey(e, from), epochKey(e)+"0", func(k string, v any) bool { // '0' follows '/'
		_, s, _ := strings.Cut(k, "/")
		if start, _ := strconv.ParseUint(s, 10, 64); to != ^uint64(0) && start > to+1 {
			return true
		}
		absorbed = append(absorbed, k)
		if hi := v.(uint64); hi > to {
			to = hi
		}
		return false
	})
	for _, k := range absorbed {
		g.cancels.Remove(k)
	}
	g.cancels.Set(dispatchKey(e, from), to)
}

func enrollKey(e uint32, client string, seq uint64) string {
	s := u64s(seq)
	return epochKey(e) + "|" + client + "|" + strings.Repeat("0", 20-len(s)) + s
}

// indexDispatch records what a newly bound dispatch tells later answers: a
// kind 1's ranges (cancelledHere), a kind 6 op 1's router client (the kind
// 10 rule). The params are this realm's own encoding.
func indexDispatch(g *routeGov, d *dispatch) {
	params := d.body[envelopeHeader:]
	switch d.kind {
	case KindCancel:
		n, ok := abiWord(params, 1)
		for i := uint64(0); ok && i < n && i < maxCancelRanges; i++ {
			from, ok1 := abiWord(params, int(2+2*i))
			to, ok2 := abiWord(params, int(3+2*i))
			if ok1 && ok2 && from <= to {
				addCancelled(g, d.epoch, from, to)
			}
		}
	case KindClient:
		if op, ok := abiWord(params, 0); ok && op == 1 {
			if id, ok := abiStringAt(params, 1); ok {
				g.enrolls.Set(enrollKey(d.epoch, id, d.seq), true)
			}
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

// abiStringAt is the string whose offset is params' i-th head word.
func abiStringAt(p []byte, i int) (string, bool) {
	off, ok := abiWord(p, i)
	if !ok || off > uint64(len(p)) || off%32 != 0 {
		return "", false
	}
	n, ok := abiWord(p, int(off/32))
	if !ok || n > uint64(len(p))-off-32 {
		return "", false
	}
	return string(p[off+32 : off+32+n]), true
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
	case d.kind == KindRouteReplace:
		return spentRouteReplacement(g, d)
	case d.status == StatusCancelled:
		return what + " is cancelled by a cancel of this realm"
	}
	return what + " is not burned (" + d.event + ")"
}

// spentRouteReplacement is why the kind 10 d is not one IBCAdmin spends for
// its unknown new client (see above), or "".
func spentRouteReplacement(g *routeGov, d *dispatch) string {
	what := "kind 10 " + u64s(d.seq)
	switch d.status {
	case StatusRecorded, StatusBuffered, StatusDuplicate, StatusSpent:
	default:
		return what + " is not burned, and Ethereum does not hold it (" + d.event + ")"
	}
	target, ok := abiStringAt(d.body[envelopeHeader:], 1)
	if !ok {
		return what + " names no new client"
	}
	found := false
	g.enrolls.Iterate(enrollKey(d.epoch, target, 0), enrollKey(d.epoch, target, d.seq), func(k string, _ any) bool {
		seq, _ := strconv.ParseUint(k[strings.LastIndex(k, "|")+1:], 10, 64)
		k6 := dispatchOf(g, d.epoch, seq)
		found = k6 != nil && k6.burned && k6.reboundTo > d.seq
		return found
	})
	if !found {
		return what + " is not burned, and no kind 6 enrolling " + target + " before it was burned and rebound past it"
	}
	return ""
}

// Rebind binds every burned dispatch of route's current epoch e numbered
// from to to (inclusive, at most 64 numbers) to the epoch's next numbers, in
// their original order, with the same kind and params in fresh envelopes,
// and sends them (see above). Anyone may call it; it returns the numbers it
// bound. A kind 10 waiting on a kind 6 in the same range follows the kind
// 6's copy. Refused for a past epoch, an empty or oversized range, and a
// range holding no rebindable dispatch; dispatches in the range that are not
// rebindable (not burned, cancelled by this realm, rebound already) are
// left as they are. Every check of a dispatch applies (bind): a paused core
// or an unusable epoch client refuses the whole call.
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
		// Checked as the loop goes: a kind 10 follows a kind 6 rebound
		// earlier in this call.
		if why := rebindable(g, d); why != "" {
			if len(out) == 0 {
				refusal = why
			}
			continue
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
