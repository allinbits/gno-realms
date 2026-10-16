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
// then spends the decision (recorded, no effect, never retried). A guardian
// hold defers every queued decision, except a guardian replacement after day
// 21 of the hold, and spends every unpause.

// unpauser is implemented by the parameters of an unpause decision, which a
// guardian hold spends.
type unpauser interface{ unpause() }

// applier is implemented by every gno-side decision's parameters: apply makes
// the change and returns a note, or the reason it cannot apply now.
type applier interface {
	apply(cur realm, t int64) (note, refusal string)
}

// decide records a decision and applies it at once, or queues it for the
// 7-day delay.
func decide(cur realm, kind, text string, params applier, made, t int64, queued bool) *decisions.Decision {
	if queued {
		d := ledger.Record(kind, text, params, made, t, t+decisions.Delay)
		d.Note = "queued 7 days"
		chain.Emit("Decision", "id", itoa(d.ID), "kind", kind, "state", "queued", "due", itoa(d.Due))
		return d
	}
	d := ledger.Record(kind, text, params, made, t, t)
	applyDecision(cur, d, t)
	return d
}

func applyDecision(cur realm, d *decisions.Decision, t int64) {
	p := d.Params.(applier)
	if _, ok := p.(unpauser); ok && heldAt(t) {
		ledger.Spend(d, "spent: a guardian hold stands, which spends every unpause")
		chain.Emit("Decision", "id", itoa(d.ID), "kind", d.Kind, "state", "spent")
		return
	}
	note, refusal := p.apply(cur, t)
	if refusal != "" {
		ledger.Spend(d, "spent: "+refusal)
		chain.Emit("Decision", "id", itoa(d.ID), "kind", d.Kind, "state", "spent")
		return
	}
	ledger.Apply(d, t, note)
	chain.Emit("Decision", "id", itoa(d.ID), "kind", d.Kind, "state", "applied")
}

// Execute applies queued decision id once its delay has passed. Anyone may
// call it. A guardian hold defers it (it stays pending), except a guardian
// replacement from day 21 of the hold on.
func Execute(cur realm, id int64) {
	t := now()
	d, err := ledger.Due(id, t)
	if err != nil {
		panic("ibcgov: " + err.Error())
	}
	if heldAt(t) {
		if _, ok := d.Params.(*seatsParams); !ok || t < holdSince+holdReplacementWait {
			panic("ibcgov: decision " + itoa(id) + " is deferred: a guardian hold stands since " + itoa(holdSince))
		}
	}
	applyDecision(cur, d, t)
}

// cancelParams withdraws a pending gno-side decision.
type cancelParams struct{ id int64 }

func (p *cancelParams) apply(cur realm, t int64) (string, string) {
	d, err := ledger.Cancel(p.id, t)
	if err != nil {
		return "", err.Error()
	}
	chain.Emit("Decision", "id", itoa(d.ID), "kind", d.Kind, "state", "cancelled")
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
		decide(cur, "cancel", text, &cancelParams{id: id}, made, t, false)
	})
}

// Decision is decision id, by value, and whether it exists.
func Decision(id int64) (decisions.Decision, bool) { return ledger.Find(id) }

// LastDecision is the number of the newest decision.
func LastDecision() int64 { return ledger.Last() }
