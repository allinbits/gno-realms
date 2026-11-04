package transfer

import "gno.land/r/gov/dao"

// GovDAO proposal constructor for the tightening operation of this realm; see
// r/aib/ibc/core/proposals.gno for the mechanism and the submission flow.
// Every loosening operation (unblocking, upgrades, membership, the Ethereum
// route controls) is a decision of gno.land/r/aib/ibc/ibcgov (ADR pr6375 R14).

const proposalTitlePrefix = "gno.land/r/aib/ibc/apps/transfer: "

func newProposalRequest(_ int, rlm realm, title, description string, cb func(cur realm) error) dao.ProposalRequest {
	return dao.NewProposalRequest(proposalTitlePrefix+title, description, dao.NewSimpleExecutor(0, rlm, cb, ""))
}

// NewBlockAddressProposalRequest proposes to block addr from sending and receiving.
func NewBlockAddressProposalRequest(cur realm, addr address) dao.ProposalRequest {
	return newProposalRequest(0, cur, "block address "+string(addr),
		"Block "+string(addr)+" in the IBC transfer app: it can no longer send, and packets addressed to it are refused with an error acknowledgement. Refunds already owed to it still go through. Unblocking is a decision of gno.land/r/aib/ibc/ibcgov.",
		func(cur realm) error { blockAddress(0, cur, addr); return nil })
}
