package transfer

import (
	"chain"

	"gno.land/p/aib/authority"
	"gno.land/p/nt/bptree/v0"
)

const (
	EventTypeBlock                  = "block"
	EventTypeUnblock                = "unblock"
	EventTypeAuthorityMemberAdded   = "authority_member_added"
	EventTypeAuthorityMemberRemoved = "authority_member_removed"
)

var (
	// auth gates every administrative operation: the blocklist and its own
	// membership. Pausing the app is the IBC core's job (core.PauseApp). Bootstrapped at init with the deployer
	// (the AIB multisig on mainnet) and the GovDAO proxy, which acts through
	// the proposal constructors in proposals.gno. Same model as
	// r/aib/ibc/core/admin.gno.
	auth    *authority.Authority
	blocked = bptree.NewBPTree32() // address -> true
)

func init(cur realm) {
	auth = authority.New(cur.Previous().Address())
}

// Exported administrative functions are thin crossing wrappers over
// non-crossing helpers, which the GovDAO proposal callbacks invoke; see
// r/aib/ibc/core/admin.gno for why.

// AddAuthorityMember adds a member to the authority. Members only.
func AddAuthorityMember(cur realm, addr address) {
	addAuthorityMember(0, cur, addr)
}

func addAuthorityMember(_ int, rlm realm, addr address) {
	auth.AddMember(0, rlm, addr)
	chain.Emit(EventTypeAuthorityMemberAdded, "address", string(addr))
}

// RemoveAuthorityMember removes a member; the last one cannot be removed.
// Members only.
func RemoveAuthorityMember(cur realm, addr address) {
	removeAuthorityMember(0, cur, addr)
}

func removeAuthorityMember(_ int, rlm realm, addr address) {
	auth.RemoveMember(0, rlm, addr)
	chain.Emit(EventTypeAuthorityMemberRemoved, "address", string(addr))
}

// IsAuthorityMember reports whether addr may administer this realm.
func IsAuthorityMember(addr address) bool {
	return auth.IsMember(addr)
}

// BlockAddress adds addr to the blocklist. A blocked address can no longer
// send (OnSendPacket rejects it, so Transfer fails) nor receive (OnRecvPacket
// answers with an error acknowledgement, so the counterparty refunds its
// sender). Refunds to a blocked sender through OnAcknowledgementPacket and
// OnTimeoutPacket still go through: blocking never confiscates funds that were
// already in flight. Members only.
func BlockAddress(cur realm, addr address) {
	blockAddress(0, cur, addr)
}

func blockAddress(_ int, rlm realm, addr address) {
	auth.Assert(0, rlm, "block_address")
	blocked.Set(string(addr), true)
	chain.Emit(EventTypeBlock, "address", string(addr))
}

// UnblockAddress removes addr from the blocklist. Members only.
func UnblockAddress(cur realm, addr address) {
	unblockAddress(0, cur, addr)
}

func unblockAddress(_ int, rlm realm, addr address) {
	auth.Assert(0, rlm, "unblock_address")
	blocked.Remove(string(addr))
	chain.Emit(EventTypeUnblock, "address", string(addr))
}

// IsBlocked reports whether addr is on the blocklist.
func IsBlocked(addr address) bool {
	return blocked.Has(string(addr))
}
