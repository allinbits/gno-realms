package transfer

import (
	"chain"

	"gno.land/p/aib/authority/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	EventTypeBlock                  = "block"
	EventTypeUnblock                = "unblock"
	EventTypeAuthorityMemberAdded   = "authority_member_added"
	EventTypeAuthorityMemberRemoved = "authority_member_removed"
)

// IBCGovPath is the governance realm of the IBC realms (ADR pr6375 R11,
// R14). Every power that loosens something here (an implementation upgrade,
// unblocking an address, the authority's membership, the Ethereum route
// controls of GovApply) is gated on a call from it, so no decision skips its
// delay.
const IBCGovPath = "gno.land/r/aib/ibc/ibcgov"

var (
	// auth gates the immediate, tightening operation BlockAddress. Its members
	// are fixed at init to the GovDAO proxy, which acts through the proposal
	// constructors in proposals.gno, and the ibcgov realm; there is no
	// deployer member (ADR pr6375 R14). Pausing the app is the IBC core's job
	// (core.PauseApp); the per-route flags of the Ethereum route are ibcgov's.
	auth    *authority.Authority
	blocked = bptree.NewBPTree32() // address -> true
)

func init(cur realm) {
	auth = authority.NewWithMembers(
		chain.PackageAddress(authority.GovDAOPath),
		chain.PackageAddress(IBCGovPath),
	)
}

// assertGovernance panics unless the caller of the crossing function whose
// cur it is passed (a non-crossing call) is the ibcgov realm.
func assertGovernance(cur realm, op string) {
	if p := cur.Previous().PkgPath(); p != IBCGovPath {
		caller := p
		if caller == "" {
			caller = string(cur.Previous().Address())
		}
		panic(ufmt.Sprintf("%s: only %s decides this, not %s", op, IBCGovPath, caller))
	}
}

// BlockAddress, the tightening operation, is a thin crossing wrapper over a
// non-crossing helper, which the GovDAO proposal callback invokes; see
// r/aib/ibc/core/admin.gno for why.

// AddAuthorityMember adds a member to the authority. Governance only.
func AddAuthorityMember(cur realm, addr address) {
	assertGovernance(cur, "add_authority_member")
	addr = mustCanonicalAddress(addr)
	auth.AddMember(0, cur, addr)
	chain.Emit(EventTypeAuthorityMemberAdded, "address", string(addr))
}

// RemoveAuthorityMember removes a member; the last one cannot be removed.
// Governance only.
func RemoveAuthorityMember(cur realm, addr address) {
	assertGovernance(cur, "remove_authority_member")
	addr = mustCanonicalAddress(addr)
	if addr == chain.PackageAddress(IBCGovPath) {
		// ibcgov changes membership as a member: removing it would freeze
		// the membership and its tightening powers for good.
		panic("remove_authority_member: the governance realm stays a member")
	}
	auth.RemoveMember(0, cur, addr)
	chain.Emit(EventTypeAuthorityMemberRemoved, "address", string(addr))
}

// AuthorityMembers returns the members of the authority.
func AuthorityMembers() []address {
	return auth.Members()
}

// IsAuthorityMember reports whether addr may block addresses.
func IsAuthorityMember(addr address) bool {
	if canonical, ok := CanonicalAddress(string(addr)); ok {
		addr = canonical
	}
	return auth.IsMember(addr)
}

// BlockAddress adds addr to the blocklist. A blocked address can no longer
// send (OnSendPacket rejects it, so Transfer fails) nor receive (OnRecvPacket
// answers with an error acknowledgement, so the counterparty refunds its
// sender). Refunds to a blocked sender through OnAcknowledgementPacket and
// OnTimeoutPacket still go through: blocking never confiscates funds that were
// already in flight. Authority members only (GovDAO or ibcgov).
func BlockAddress(cur realm, addr address) {
	blockAddress(0, cur, addr)
}

func blockAddress(_ int, rlm realm, addr address) {
	auth.Assert(0, rlm, "block_address")
	canonical := mustCanonicalAddress(addr)
	blocked.Set(string(canonical), true)
	chain.Emit(EventTypeBlock, "address", string(canonical))
}

// UnblockAddress removes addr from the blocklist. Governance only.
func UnblockAddress(cur realm, addr address) {
	assertGovernance(cur, "unblock_address")
	canonical := mustCanonicalAddress(addr)
	blocked.Remove(string(canonical))
	chain.Emit(EventTypeUnblock, "address", string(canonical))
}

// IsBlocked reports whether addr is on the blocklist, whatever its spelling.
// The blocklist is keyed by canonical addresses (see CanonicalAddress); an
// invalid address is never blocked.
func IsBlocked(addr address) bool {
	canonical, ok := CanonicalAddress(string(addr))
	return ok && blocked.Has(string(canonical))
}

func mustCanonicalAddress(addr address) address {
	canonical, ok := CanonicalAddress(string(addr))
	if !ok {
		panic("invalid address: " + string(addr))
	}
	return canonical
}

// BlockedAddresses returns the blocklist, sorted.
func BlockedAddresses() []address {
	out := make([]address, 0, blocked.Size())
	blocked.Iterate("", "", func(k string, _ any) bool {
		out = append(out, address(k))
		return false
	})
	return out
}
