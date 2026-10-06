package core

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/aib/authority/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	EventTypePause                  = "pause"
	EventTypeUnpause                = "unpause"
	EventTypeAuthorityMemberAdded   = "authority_member_added"
	EventTypeAuthorityMemberRemoved = "authority_member_removed"
)

var (
	// auth gates every administrative operation: the relayer whitelist, the
	// pause switch, RecoverClient and its own membership. It is bootstrapped
	// at init with two members, the deployer (the AIB multisig on mainnet)
	// and the GovDAO proxy, which acts through the proposal constructors in
	// proposals.gno. The principal is cur.Previous().Address(): a direct
	// MsgCall from a member, or a GovDAO callback declared in this realm. A
	// call routed through another realm, or through MsgRun, presents that
	// realm's address and is refused.
	auth     *authority.Authority
	relayers = bptree.NewBPTree32()
	paused   bool
)

func init(cur realm) {
	// cur.Previous() is the deployer during init: the creator of the package,
	// both for MsgAddPackage and for MsgEnablePackage on an inert chain. In
	// the gno test framework it is empty; see p/aib/authority for the
	// bootstrap that filetests use.
	auth = authority.New(cur.Previous().Address())
}

// Every exported administrative function below is a thin crossing wrapper
// over a non-crossing (_ int, rlm realm, ...) helper. The helpers are what the
// GovDAO proposal callbacks (proposals.gno) invoke: a callback runs with this
// realm's live cur whose Previous() is the GovDAO proxy, whereas a crossing
// call from inside the callback would present this realm itself.

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

// AddRelayer adds an address to the authorized relayer whitelist. Members only.
func AddRelayer(cur realm, addr address) {
	addRelayer(0, cur, addr)
}

func addRelayer(_ int, rlm realm, addr address) {
	auth.Assert(0, rlm, "add_relayer")
	relayers.Set(string(addr), true)
}

// RemoveRelayer removes an address from the authorized relayer whitelist.
// Members only.
func RemoveRelayer(cur realm, addr address) {
	removeRelayer(0, cur, addr)
}

func removeRelayer(_ int, rlm realm, addr address) {
	auth.Assert(0, rlm, "remove_relayer")
	relayers.Remove(string(addr))
}

// Pause suspends the packet path: SendPacket, RecvPacket, WriteAcknowledgement,
// Acknowledgement and Timeout panic until Unpause. Client operations
// (CreateClient, RegisterCounterparty, UpdateClient, UpgradeClient,
// RecoverClient) keep working, so clients do not expire during a pause.
// Members only.
func Pause(cur realm) {
	pause(0, cur)
}

func pause(_ int, rlm realm) {
	auth.Assert(0, rlm, "pause")
	paused = true
	chain.Emit(EventTypePause)
}

// Unpause resumes the packet path. Members only.
func Unpause(cur realm) {
	unpause(0, cur)
}

func unpause(_ int, rlm realm) {
	auth.Assert(0, rlm, "unpause")
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
