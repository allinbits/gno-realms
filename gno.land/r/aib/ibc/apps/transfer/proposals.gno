package transfer

import "gno.land/r/gov/dao"

// GovDAO proposal constructors for the gated operations of this realm; see
// r/aib/ibc/core/proposals.gno for the mechanism and the submission flow.

const proposalTitlePrefix = "gno.land/r/aib/ibc/apps/transfer: "

func newProposalRequest(_ int, rlm realm, title, description string, cb func(cur realm) error) dao.ProposalRequest {
	return dao.NewProposalRequest(proposalTitlePrefix+title, description, dao.NewSimpleExecutor(0, rlm, cb, ""))
}

// NewBlockAddressProposalRequest proposes to block addr from sending and receiving.
func NewBlockAddressProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "block address "+string(addr),
		"Block "+string(addr)+" in the IBC transfer app: it can no longer send, and packets addressed to it are refused with an error acknowledgement. Refunds already owed to it still go through.",
		func(cur realm) error { blockAddress(0, cur, addr); return nil })
}

// NewUnblockAddressProposalRequest proposes to unblock addr.
func NewUnblockAddressProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "unblock address "+string(addr),
		"Unblock "+string(addr)+" in the IBC transfer app.",
		func(cur realm) error { unblockAddress(0, cur, addr); return nil })
}

// NewAddAuthorityMemberProposalRequest proposes to add a member to the authority.
func NewAddAuthorityMemberProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "add authority member "+string(addr),
		"Add "+string(addr)+" to the authority of the IBC transfer app, which administers the pause switch, the blocklist and its own membership.",
		func(cur realm) error { addAuthorityMember(0, cur, addr); return nil })
}

// NewRemoveAuthorityMemberProposalRequest proposes to remove a member from the authority.
func NewRemoveAuthorityMemberProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "remove authority member "+string(addr),
		"Remove "+string(addr)+" from the authority of the IBC transfer app.",
		func(cur realm) error { removeAuthorityMember(0, cur, addr); return nil })
}

// NewUpdateImplProposalRequest proposes to activate a registered implementation.
func NewUpdateImplProposalRequest(cur realm, path string) dao.ProposalRequest {
	return newProposalRequest(0, cur, "update implementation to "+path,
		"Activate the implementation registered at "+path+" as the ICS-20 logic of the IBC transfer app. Its OnInstall hook runs any migration; a panic there leaves the current implementation active.",
		func(cur realm) error { updateImpl(0, cur, path); return nil })
}
