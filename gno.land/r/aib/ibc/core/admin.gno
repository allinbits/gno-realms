package core

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/aib/authority/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	EventTypePause                  = "pause"
	EventTypeUnpause                = "unpause"
	EventTypeAuthorityMemberAdded   = "authority_member_added"
	EventTypeAuthorityMemberRemoved = "authority_member_removed"
	EventTypeClientRetired          = "client_retired"
)

// IBCGovPath is the governance realm of the IBC realms (ADR pr6375 R11, R14):
// it holds the decision ledger, the governor and its one-way yield to GovDAO,
// and the 7-day delays. Every power that loosens something here (an
// implementation upgrade, the relayer list, unpausing, approving an app,
// recovering, migrating or retiring a client, the authority's membership) is
// gated on a call from it, so no decision skips its delay.
const IBCGovPath = "gno.land/r/aib/ibc/ibcgov"

var (
	// auth gates the immediate, tightening operations: Pause, PauseApp and
	// RejectApp. Its members are fixed at init to the GovDAO proxy, which acts
	// through the proposal constructors in proposals.gno, and the ibcgov
	// realm; there is no deployer member (ADR pr6375 R14). The principal is
	// cur.Previous().Address(): a GovDAO callback declared in this realm, or a
	// crossing call from ibcgov. Membership changes are governance decisions.
	auth     *authority.Authority
	relayers = bptree.NewBPTree32()
	paused   bool
)

func init(cur realm) {
	auth = authority.NewWithMembers(
		chain.PackageAddress(authority.GovDAOPath),
		chain.PackageAddress(IBCGovPath),
	)
}

// The tightening functions below are thin crossing wrappers over non-crossing
// (_ int, rlm realm, ...) helpers. The helpers are what the GovDAO proposal
// callbacks (proposals.gno) invoke: a callback runs with this realm's live cur
// whose Previous() is the GovDAO proxy, whereas a crossing call from inside
// the callback would present this realm itself.

// assertGovernance panics unless the caller of the realm function holding rlm
// is the ibcgov realm. rlm must be that function's live cur.
func assertGovernance(_ int, rlm realm, op string) {
	if !rlm.IsCurrent() {
		panic(op + ": rlm is not the caller's live realm")
	}
	if p := rlm.Previous().PkgPath(); p != IBCGovPath {
		caller := p
		if caller == "" {
			caller = string(rlm.Previous().Address())
		}
		panic(ufmt.Sprintf("%s: only %s decides this, not %s", op, IBCGovPath, caller))
	}
}

// AddAuthorityMember adds a member to the authority. Governance only.
func AddAuthorityMember(cur realm, addr address) {
	assertGovernance(0, cur, "add_authority_member")
	auth.AddMember(0, cur, addr)
	chain.Emit(EventTypeAuthorityMemberAdded, "address", string(addr))
}

// RemoveAuthorityMember removes a member; the last one cannot be removed.
// Governance only.
func RemoveAuthorityMember(cur realm, addr address) {
	assertGovernance(0, cur, "remove_authority_member")
	auth.RemoveMember(0, cur, addr)
	chain.Emit(EventTypeAuthorityMemberRemoved, "address", string(addr))
}

// AuthorityMembers returns the members of the authority.
func AuthorityMembers() []address {
	return auth.Members()
}

// IsAuthorityMember reports whether addr may run the tightening operations.
func IsAuthorityMember(addr address) bool {
	return auth.IsMember(addr)
}

// AddRelayer adds an address to the authorized relayer whitelist. Governance
// only.
func AddRelayer(cur realm, addr address) {
	assertGovernance(0, cur, "add_relayer")
	relayers.Set(string(addr), true)
}

// RemoveRelayer removes an address from the authorized relayer whitelist.
// Governance only: removing the last one opens relaying to anyone.
func RemoveRelayer(cur realm, addr address) {
	assertGovernance(0, cur, "remove_relayer")
	relayers.Remove(string(addr))
}

// Relayers returns the relayer whitelist, empty when any relayer is allowed.
func Relayers() []address {
	out := make([]address, 0, relayers.Size())
	relayers.Iterate("", "", func(k string, _ any) bool {
		out = append(out, address(k))
		return false
	})
	return out
}

// Pause suspends the packet path: SendPacket, RecvPacket, WriteAcknowledgement,
// Acknowledgement and Timeout panic until Unpause. Client operations
// (CreateClient, RegisterCounterparty, UpdateClient, UpgradeClient,
// RecoverClient) keep working, so clients do not expire during a pause. It
// blocks refunds too, so it is reserved for a core bug (ADR pr6375 §7.3).
// Authority members only; see proposals.gno for the GovDAO path.
func Pause(cur realm) {
	pause(0, cur)
}

func pause(_ int, rlm realm) {
	auth.Assert(0, rlm, "pause")
	paused = true
	chain.Emit(EventTypePause)
}

// Unpause resumes the packet path. Governance only.
func Unpause(cur realm) {
	assertGovernance(0, cur, "unpause")
	paused = false
	chain.Emit(EventTypeUnpause)
}

// Paused reports whether the packet path is suspended.
func Paused() bool {
	return paused
}

// ensureNotPaused panics if the packet path is suspended.
func ensureNotPaused() {
	if paused {
		panic("core is paused")
	}
}

// RetireClient retires a client for good: every packet message, client update
// and counterparty registration naming it is refused from now on, whatever
// its verifier's status. A route replacement (ADR pr6375 §7.12, R18) retires
// the old client of a route that a new client replaces, after which the old
// route's packets are settled by reconciliation. Governance only.
func RetireClient(cur realm, clientID string) {
	assertGovernance(0, cur, "retire_client")
	if store.getClient(clientID) == nil {
		panic(ufmt.Sprintf("client %s not found", clientID))
	}
	if store.isRetired(clientID) {
		panic(ufmt.Sprintf("client %s is retired already", clientID))
	}
	store.retired.Set(clientID, true)
	chain.Emit(EventTypeClientRetired, "client_id", clientID)
}

// IsClientRetired reports whether RetireClient retired clientID.
func IsClientRetired(clientID string) bool {
	return store.isRetired(clientID)
}

// ensureNotRetired panics if clientID was retired.
func ensureNotRetired(clientID string) {
	if store.isRetired(clientID) {
		panic(ufmt.Sprintf("client %s is retired", clientID))
	}
}

// ensureAuthorizedRelayer panics if the EOA that signed the tx is not in the
// relayer whitelist. If the whitelist is empty any EOA is allowed. Returns the
// relayer's EOA address.
//
// Unlike the authority above, this gate is bound to the transaction signer
// (unsafe.OriginCaller): relaying is a high-frequency, per-key operation that
// the relayer may legitimately route through its own MsgRun scripts, and a
// relayer key never acts through governance. Trade-off: the signer can relay
// through any intermediate realm, the same tx.origin risk class as v1's
// runtime.OriginCaller.
func ensureAuthorizedRelayer() address {
	caller := unsafe.OriginCaller()
	if relayers.Size() == 0 {
		return caller
	}
	if !relayers.Has(string(caller)) {
		panic(ufmt.Sprintf("unauthorized relayer %s", caller))
	}
	return caller
}

// ensureRelayerFor is ensureAuthorizedRelayer for a message whose proof is
// checked against clientID. Relaying for an Ethereum client is permissionless
// (ADR pr6375 R17): its updates, receives, acknowledgements and timeouts are
// all proof-checked, and a refund must never wait on a listed relayer, so the
// whitelist does not apply. Any other client keeps the whitelist.
func ensureRelayerFor(clientID string) address {
	if c := store.getClient(clientID); c != nil && c.typ == ethereum.ClientType {
		return unsafe.OriginCaller()
	}
	return ensureAuthorizedRelayer()
}
