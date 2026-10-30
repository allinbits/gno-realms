package core

import "gno.land/r/gov/dao"

// GovDAO is a member of the authority (p/aib/authority.GovDAOPath) but cannot
// call a realm directly: it executes a callback. The constructors below build
// the ProposalRequest whose callback, declared in this realm, runs the gated
// operation through its non-crossing helper; inside the callback cur.Previous()
// is gno.land/r/gov/dao, so the gate sees the DAO's address. The callbacks are
// unexported closures capturing their arguments, so this realm exports no bare
// func(realm) error that the DAO could be made to invoke on someone else's
// behalf.
//
// Only the tightening operations have a direct GovDAO path: they take effect
// at once and can only stop things. Every loosening operation (unpausing,
// relayers, recovery, approvals, upgrades, migrations, membership) is a
// decision of gno.land/r/aib/ibc/ibcgov, with its delay (ADR pr6375 R14).
//
// A GovDAO member submits one with MsgRun, members vote, anyone executes:
//
//	dao.MustCreateProposal(cross(cur), core.NewPauseProposalRequest(cross(cur)))
//	gnokey maketx call -pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple -args <pid> -args YES ...
//	gnokey maketx call -pkgpath gno.land/r/gov/dao -func ExecuteProposal -args <pid> ...
//
// A failing callback panics, which aborts the execution transaction and leaves
// the proposal executable again once the cause is fixed.

const proposalTitlePrefix = "gno.land/r/aib/ibc/core: "

func newProposalRequest(_ int, rlm realm, title, description string, cb func(cur realm) error) dao.ProposalRequest {
	return dao.NewProposalRequest(proposalTitlePrefix+title, description, dao.NewSimpleExecutor(0, rlm, cb, ""))
}

// NewPauseProposalRequest proposes to suspend the packet path.
func NewPauseProposalRequest(cur realm) dao.ProposalRequest {
	return newProposalRequest(0, cur, "pause",
		"Suspend the IBC core packet path (SendPacket, RecvPacket, WriteAcknowledgement, Acknowledgement, Timeout). Client operations keep working. Resuming it is a decision of gno.land/r/aib/ibc/ibcgov.",
		func(cur realm) error { pause(0, cur); return nil })
}

// NewRejectAppProposalRequest proposes to drop a pending app registration.
func NewRejectAppProposalRequest(cur realm, portID, pkgPath string) dao.ProposalRequest {
	return newProposalRequest(0, cur, "reject app "+pkgPath+" on port "+portID,
		"Drop the pending registration of the realm "+pkgPath+" for port "+portID+" of the IBC core.",
		func(cur realm) error { rejectApp(0, cur, portID, pkgPath); return nil })
}

// NewPauseAppProposalRequest proposes to suspend the application on portID.
func NewPauseAppProposalRequest(cur realm, portID string) dao.ProposalRequest {
	return newProposalRequest(0, cur, "pause app "+portID,
		"Suspend the IBC application registered on port "+portID+": sends for that port are refused and incoming packets are answered with an error acknowledgement, so counterparties refund their senders. Acknowledgement and timeout callbacks keep running. Resuming it is a decision of gno.land/r/aib/ibc/ibcgov.",
		func(cur realm) error { pauseApp(0, cur, portID); return nil })
}
