package ibcgov

import (
	"chain"

	"gno.land/p/aib/decisions/v0"
	"gno.land/r/gov/dao"
)

// Request is what a builder returns: the proposal GovDAO's proxy executes
// after the yield (Proposal), and the same decision the governor runs
// directly before it (Govern). The closure is one; only who may run it
// changes with the yield. A Request comes from a builder alone: its fields are
// unexported, so no other code can build one or change what it decides, and a
// stranger holding one can only hand it back to Govern, which refuses
// everyone but the governor.
type Request struct {
	proposal dao.ProposalRequest
	text     string
	decide   func(cur realm) error
}

// Proposal is the request as a GovDAO proposal:
// dao.MustCreateProposal(cross(cur), req.Proposal()).
func (r Request) Proposal() dao.ProposalRequest { return r.proposal }

// Description is the proposal's description: the parameters as the builder
// wrote them.
func (r Request) Description() string { return r.text }

// mustBeGovernor is a decision's identity check, read from the closure's own
// live cur: until the yield the governor's own transaction (a user realm with
// the governor's address: a MsgRun's ephemeral realm, never another realm),
// which is Govern's non-crossing call of the closure, with GovDAO's proposals
// refused; after it, or when no governor was compiled, the GovDAO proxy alone.
// A refusal panics, so a proposal made before the yield survives for a retry
// after it, within its 14 days.
func mustBeGovernor(cur realm) {
	prev := cur.Previous()
	if decisions.DAOGoverns(LaunchGovernor, yielded) {
		if prev.PkgPath() != decisions.DAOPath {
			panic("ibcgov: only " + decisions.DAOPath + " decides, not " + who(0, prev))
		}
		return
	}
	if !prev.IsUser() || prev.Address() != LaunchGovernor {
		panic("ibcgov: until the governor yields, " + string(LaunchGovernor) + " alone decides, by Govern from its own key: not " + who(0, prev) + " (a GovDAO proposal is refused until the yield)")
	}
}

// propose wraps a builder's effect in the closure every builder shares: the
// identity check, the 14-day deadline (an expired proposal returns an error,
// which GovDAO takes as a denial for good) and the effect, which records the
// decision. made is when the builder ran.
func propose(cur realm, kind, text string, effect func(cur realm, made, t int64)) Request {
	made := now()
	cb := func(cur realm) error {
		mustBeGovernor(cur)
		t := now()
		if err := decisions.Expired(made, t); err != nil {
			return err
		}
		effect(cur, made, t)
		return nil
	}
	return Request{
		proposal: dao.NewProposalRequest(titlePrefix+kind, text, dao.NewSimpleExecutor(0, cur, cb, text)),
		text:     text,
		decide:   cb,
	}
}

// Govern is the governor's way in before the yield: the governor, by its own
// transaction (the MsgRun that builds the request), makes a builder's decision
// directly, through the same closure GovDAO's proxy runs after the yield: the
// same checks, at-once test, 7-day queue and record. Refused for anyone else,
// and for everyone once the governor yielded or when none was compiled.
func Govern(cur realm, r Request) {
	if r.decide == nil {
		panic("ibcgov: not a builder's request")
	}
	if decisions.DAOGoverns(LaunchGovernor, yielded) {
		panic("ibcgov: " + governedBy() + ": a decision is a GovDAO proposal, never Govern")
	}
	mustBeGovernor(cur)
	if err := r.decide(cur); err != nil {
		panic("ibcgov: " + err.Error())
	}
}

func governedBy() string {
	if LaunchGovernor == "" {
		return "no governor was compiled, " + decisions.DAOPath + " governs from the first block"
	}
	return "the governor yielded at height " + itoa(yielded) + ", " + decisions.DAOPath + " governs since"
}

// Yield is the governor's one-way hand-over to GovDAO (ADR pr6375 §7.7): from
// this block GovDAO's proposals are the only way a decision is made, and
// Govern is closed for good. The governor alone, by its own transaction. A
// decision the governor queued still applies by Execute after its delay, or a
// cancel decision withdraws it.
func Yield(cur realm) {
	if LaunchGovernor == "" {
		panic("ibcgov: no governor was compiled: " + decisions.DAOPath + " governs from the first block")
	}
	if yielded != 0 {
		panic("ibcgov: the governor yielded at height " + itoa(yielded) + " already")
	}
	prev := cur.Previous()
	if !prev.IsUser() || prev.Address() != LaunchGovernor {
		panic("ibcgov: only the governor " + string(LaunchGovernor) + " yields, not " + who(0, prev))
	}
	yielded = chainHeight()
	chain.Emit("Yielded", "governor", string(LaunchGovernor), "height", itoa(yielded))
}

// Governor is the compiled governor key, and Yielded the height of its yield
// (0 before).
func Governor() address { return LaunchGovernor }
func Yielded() int64    { return yielded }

// GovDAOGoverns reports whether GovDAO's proposals decide now.
func GovDAOGoverns() bool { return decisions.DAOGoverns(LaunchGovernor, yielded) }
