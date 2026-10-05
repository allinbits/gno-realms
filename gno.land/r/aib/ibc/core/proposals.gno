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
// A GovDAO member submits one with MsgRun, members vote, anyone executes:
//
//	dao.MustCreateProposal(cross(cur), core.NewAddRelayerProposalRequest(cross(cur), addr))
//	gnokey maketx call -pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple -args <pid> -args YES ...
//	gnokey maketx call -pkgpath gno.land/r/gov/dao -func ExecuteProposal -args <pid> ...
//
// A failing callback panics, which aborts the execution transaction and leaves
// the proposal executable again once the cause is fixed.

const proposalTitlePrefix = "gno.land/r/aib/ibc/core: "

func newProposalRequest(_ int, rlm realm, title, description string, cb func(cur realm) error) dao.ProposalRequest {
	return dao.NewProposalRequest(proposalTitlePrefix+title, description, dao.NewSimpleExecutor(0, rlm, cb, ""))
}

// NewAddRelayerProposalRequest proposes to add addr to the relayer whitelist.
func NewAddRelayerProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "add relayer "+string(addr),
		"Add "+string(addr)+" to the relayer whitelist of the IBC core. Once the whitelist is non-empty, only listed accounts may create and update clients and relay packets.",
		func(cur realm) error { addRelayer(0, cur, addr); return nil })
}

// NewRemoveRelayerProposalRequest proposes to remove addr from the relayer whitelist.
func NewRemoveRelayerProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "remove relayer "+string(addr),
		"Remove "+string(addr)+" from the relayer whitelist of the IBC core.",
		func(cur realm) error { removeRelayer(0, cur, addr); return nil })
}

// NewRecoverClientProposalRequest proposes to recover a frozen or expired client
// from a substitute one (see recover-client.md).
func NewRecoverClientProposalRequest(cur realm, subjectClientID, substituteClientID string) dao.ProposalRequest {
	return newProposalRequest(0, cur, "recover client "+subjectClientID,
		"Recover the frozen or expired client "+subjectClientID+" of the IBC core from the substitute client "+substituteClientID+", which must track the same counterparty chain and be Active.",
		func(cur realm) error { recoverClient(0, cur, subjectClientID, substituteClientID); return nil })
}

// NewPauseProposalRequest proposes to suspend the packet path.
func NewPauseProposalRequest(cur realm) dao.ProposalRequest {
	return newProposalRequest(0, cur, "pause",
		"Suspend the IBC core packet path (SendPacket, RecvPacket, WriteAcknowledgement, Acknowledgement, Timeout). Client operations keep working.",
		func(cur realm) error { pause(0, cur); return nil })
}

// NewUnpauseProposalRequest proposes to resume the packet path.
func NewUnpauseProposalRequest(cur realm) dao.ProposalRequest {
	return newProposalRequest(0, cur, "unpause",
		"Resume the IBC core packet path.",
		func(cur realm) error { unpause(0, cur); return nil })
}

// NewAddAuthorityMemberProposalRequest proposes to add a member to the authority.
func NewAddAuthorityMemberProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "add authority member "+string(addr),
		"Add "+string(addr)+" to the authority of the IBC core, which administers the relayer whitelist, the pause switch, client recovery and its own membership.",
		func(cur realm) error { addAuthorityMember(0, cur, addr); return nil })
}

// NewRemoveAuthorityMemberProposalRequest proposes to remove a member from the authority.
func NewRemoveAuthorityMemberProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "remove authority member "+string(addr),
		"Remove "+string(addr)+" from the authority of the IBC core.",
		func(cur realm) error { removeAuthorityMember(0, cur, addr); return nil })
}

// NewApproveAppProposalRequest proposes to activate a pending app registration.
func NewApproveAppProposalRequest(cur realm, portID, pkgPath string) dao.ProposalRequest {
	return newProposalRequest(0, cur, "approve app "+pkgPath+" on port "+portID,
		"Activate the pending registration of the realm "+pkgPath+" as the IBC application behind port "+portID+" of the IBC core. Once active, packets with that port are routed to it.",
		func(cur realm) error { approveApp(0, cur, portID, pkgPath); return nil })
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
		"Suspend the IBC application registered on port "+portID+": sends for that port are refused and incoming packets are answered with an error acknowledgement, so counterparties refund their senders. Acknowledgement and timeout callbacks keep running.",
		func(cur realm) error { pauseApp(0, cur, portID); return nil })
}

// NewUnpauseAppProposalRequest proposes to resume the application on portID.
func NewUnpauseAppProposalRequest(cur realm, portID string) dao.ProposalRequest {
	return newProposalRequest(0, cur, "unpause app "+portID,
		"Resume the IBC application registered on port "+portID+".",
		func(cur realm) error { unpauseApp(0, cur, portID); return nil })
}
