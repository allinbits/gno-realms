package ibcgov

import (
	"chain"

	"gno.land/p/aib/decisions/v0"
)

// The decision lifecycle (ADR pr6375 §6.6, §7.5): a decision is recorded when
// its closure runs. An at-once decision (tightening, removal, cancel, unpause
// on gno.land) applies in the same transaction; a loosening one is queued
// for decisions.Delay and anyone applies it with Execute once due. Parameters
// are re-checked against live state when the decision applies: a refusal
// then spends the decision (recorded, no effect, never retried).
//
// Every decision has a scope (ADR 0007 §6). A route-scoped decision is
// bound to the route's incarnation it was built against, and deferred only
// by that route's guardian hold: a queued one waits, except a seat change
// from day 21 of the hold, and an unpause is spent. A global decision (the
// shared core and transfer app, or a gno client of no route) is deferred by
// any route's hold, to day 21 of the global hold that first deferred it at
// most; a global unpause is deferred too, never spent.

// unpauser is implemented by the parameters of an unpause decision.
type unpauser interface{ unpause() }

// deferrer is implemented by a decision whose execution a standing flag
// defers (it stays pending): deferredBy is the reason, "" if none.
type deferrer interface{ deferredBy() string }

// applier is implemented by every gno-side decision's parameters: apply makes
// the change and returns a note, or the reason it cannot apply now.
type applier interface {
	apply(cur realm, t int64) (note, refusal string)
}

// emitDecision announces decision d's state, naming its route when it is
// route-scoped.
func emitDecision(d *decisions.Decision, state string, extra ...string) {
	attrs := []string{"id", itoa(d.ID), "kind", d.Kind, "state", state}
	if r := DecisionRoute(d.ID); r != "" {
		attrs = append(attrs, "route", r)
	}
	chain.Emit("Decision", append(attrs, extra...)...)
}

// decide records a decision of scope sc and applies it at once, or queues
// it for the 7-day delay. A scope that no longer holds when it is recorded
// (the route's record changed, a client it names belongs to another route)
// spends it at once.
func decide(cur realm, kind, text string, params applier, made, t int64, queued bool, sc scope) *decisions.Decision {
	if refusal := sc.check(); refusal != "" {
		return spendAtRecording(kind, text, params, made, t, refusal, sc)
	}
	due := t
	if queued {
		due = t + decisions.Delay
	}
	d := ledger.Record(kind, text, params, made, t, due)
	s := sc
	s.take(d.ID)
	if queued {
		d.Note = "queued 7 days"
		emitDecision(d, "queued", "due", itoa(d.Due))
		return d
	}
	applyDecision(cur, d, t)
	return d
}

// spendAtRecording records a decision refused when it is recorded: spent
// at once, its effect never applied, so the request that made it (an
// approved proposal included) is used up, never retried later.
// It keeps the decision's scope, so its route stays named (DecisionRoute, the
// event), but takes no claim and counts no pending decision.
func spendAtRecording(kind, text string, params applier, made, t int64, refusal string, sc scope) *decisions.Decision {
	d := ledger.Record(kind, text, params, made, t, t)
	s := sc
	s.claims, s.counted = nil, false
	scopes.Set(scopeKey(d.ID), &s)
	ledger.Spend(d, "spent: "+refusal)
	emitDecision(d, "spent")
	return d
}

// spend spends a pending decision and releases what it held.
func spend(d *decisions.Decision, refusal string) {
	ledger.Spend(d, "spent: "+refusal)
	resolve(d)
	emitDecision(d, "spent")
}

// holdDeadline anchors a decision bounded by a hold at base, the start of
// the hold now deferring it, on its first deferral, and returns the anchor,
// the deadline and whether this call set the anchor.
func (sc *scope) holdDeadline(base int64) (anchor, deadline int64, first bool) {
	first = sc.anchor == 0
	if first {
		sc.anchor = base
	}
	return sc.anchor, sc.anchor + holdReplacementWait, first
}

func applyDecision(cur realm, d *decisions.Decision, t int64) {
	p := d.Params.(applier)
	sc := scopeOf(d.ID)
	if sc == nil {
		sc = &scope{} // recorded before scopes: global
	}
	if _, ok := p.(unpauser); ok {
		if sc.route != "" {
			if g := govOf(sc.route); g != nil && g.heldAt(t) {
				spend(d, "route "+sc.route+"'s guardian hold stands, which spends its unpauses")
				return
			}
		} else if anyHeldAt(t) {
			// A global unpause is deferred, never spent: one route's
			// guardians must not undo it (ADR 0007 §6). It stays pending and
			// lands by Execute from day 21 of the global hold that first
			// deferred it, or once no hold stands.
			_, deadline, first := sc.holdDeadline(globalHeldSince)
			if t < deadline {
				if first {
					emitDecision(d, "deferred", "until", itoa(deadline))
				}
				return
			}
		}
	}
	note, refusal := p.apply(cur, t)
	if refusal != "" {
		spend(d, refusal)
		return
	}
	ledger.Apply(d, t, note)
	resolve(d)
	emitDecision(d, "applied")
}

// Execute applies pending decision id once its delay has passed. Anyone may
// call it. A guardian hold defers it (it stays pending): a route-scoped
// decision by its route's hold, except a seat change from day 21 of it; a
// global one by any route's hold, to day 21 of the global hold that first
// deferred it.
func Execute(cur realm, id int64) {
	t := now()
	d, err := ledger.Due(id, t)
	if err != nil {
		panic("ibcgov: " + err.Error())
	}
	sc := scopeOf(d.ID)
	if sc == nil {
		sc = &scope{}
	}
	// The route's record changed (dropped, or re-created as another
	// incarnation), or a client it names now belongs to another route, or a
	// global decision's client was claimed since: approved under rules that
	// no longer hold.
	if refusal := sc.check(); refusal != "" {
		spend(d, refusal)
		return
	}
	if sc.route != "" {
		g := govOf(sc.route)
		if g != nil && g.heldAt(t) {
			if _, ok := d.Params.(holdBounded); !ok {
				panic("ibcgov: decision " + itoa(id) + " is deferred: route " + sc.route + "'s guardian hold stands since " + itoa(g.holdSince))
			}
			// A seat change (a guardian replacement or a vacancy) lands from
			// day 21 of the route's hold that first deferred it after it
			// became due, its anchor, whatever holds stand by then: a later
			// hold, after one was cleared, never resets that deadline (ADR
			// pr6375 §7.4; Ethereum anchors it the same way). The first
			// deferral records the anchor and returns, so the record stands.
			if deferHeld(d, sc, g.holdSince, t) {
				return
			}
		}
	} else if anyHeldAt(t) {
		// Any route's hold defers a global decision, to day 21 of the global
		// hold that first deferred it at most: holds chained across routes
		// never delay it longer (ADR 0007 §6).
		if deferHeld(d, sc, globalHeldSince, t) {
			return
		}
	}
	// One flag stops a route's payouts, governed ones included: a decision
	// paying out on a flagged function waits (ADR pr6375 R10, §7.4).
	if df, ok := d.Params.(deferrer); ok {
		if reason := df.deferredBy(); reason != "" {
			panic("ibcgov: decision " + itoa(id) + " is deferred: " + reason)
		}
	}
	applyDecision(cur, d, t)
}

// deferHeld defers d under a hold that started at base until its deadline:
// it returns true on the first deferral (the record stands), panics on a
// later one before the deadline, and returns false once it passed.
func deferHeld(d *decisions.Decision, sc *scope, base, t int64) bool {
	anchor, deadline, first := sc.holdDeadline(base)
	if t >= deadline {
		return false
	}
	if first {
		emitDecision(d, "deferred", "until", itoa(deadline))
		return true
	}
	panic("ibcgov: decision " + itoa(d.ID) + " is deferred: a guardian hold first deferred it on " + itoa(anchor) + ", until " + itoa(deadline))
}

// cancelParams withdraws a pending gno-side decision.
type cancelParams struct{ id int64 }

func (p *cancelParams) apply(cur realm, t int64) (string, string) {
	d, err := ledger.Cancel(p.id, t)
	if err != nil {
		return "", err.Error()
	}
	resolve(d)
	emitDecision(d, "cancelled")
	// A cancelled expectation releases its transition's intent.
	if ep, ok := d.Params.(*expectParams); ok {
		if g := govOf(ep.route); g != nil {
			release(g, ep.from, ep.to, ep.local, ep.gen, ep.owner)
		}
	}
	return "cancelled decision " + itoa(p.id), ""
}

// NewCancelRequest withdraws pending decision id at once (ADR pr6375 §7.5:
// cancels are immediate). Guardians cannot cancel; only a decision can.
func NewCancelRequest(cur realm, id int64) Request {
	d, ok := ledger.Find(id)
	if !ok || !d.Pending() {
		panic("ibcgov: decision " + itoa(id) + " is not pending")
	}
	text := "cancel decision " + itoa(id) + " (" + d.Kind + ")"
	return propose(cur, "cancel", text, func(cur realm, made, t int64) {
		decide(cur, "cancel", text, &cancelParams{id: id}, made, t, false, globalScope())
	})
}

// Decision is decision id, by value, and whether it exists.
func Decision(id int64) (decisions.Decision, bool) { return ledger.Find(id) }

// LastDecision is the number of the newest decision.
func LastDecision() int64 { return ledger.Last() }
