// Package authority is the admin gate shared by the AIB realms: a member set
// bootstrapped with the realm's deployer and the GovDAO proxy address.
//
// The principal is the address of the realm or user that called the realm
// function holding the live cur, cur.Previous().Address(), never the
// transaction signer. A direct MsgCall from a member passes; a call routed
// through another realm, or through MsgRun, presents that realm's address and
// is refused; a GovDAO proposal callback declared by the realm presents the
// GovDAO proxy, which is a member from the start.
package authority

import (
	"chain"

	"gno.land/p/moul/addrset/v0"
	"gno.land/p/nt/ufmt/v0"
)

// GovDAOPath is the GovDAO proxy realm. Its package address is a member from
// the start: a proposal executor runs the realm's callback with the proxy as
// the previous realm, so that is the address the gate sees.
const GovDAOPath = "gno.land/r/gov/dao"

// Authority is a member set.
type Authority struct {
	members addrset.Set
	// bootstrapped is false only when the deployer could not be captured at
	// init, which happens in the gno test framework (the origin caller is
	// empty there). Until then the first AddMember is ungated and completes
	// the bootstrap. On chain, init always sees the deployer: MsgAddPackage
	// runs it as the creator, and so does MsgEnablePackage on an inert chain.
	bootstrapped bool
}

// New returns an authority whose members are deployer (skipped when empty, see
// bootstrapped) and the GovDAO proxy. Call it from the realm's
// init(cur realm) with cur.Previous().Address().
func New(deployer address) *Authority {
	a := &Authority{}
	if deployer != "" {
		a.members.Add(deployer)
		a.bootstrapped = true
	}
	a.members.Add(chain.PackageAddress(GovDAOPath))
	return a
}

// Assert panics unless the caller of the realm function holding rlm is a
// member. rlm must be that realm's live cur: a stored or forwarded realm value
// is rejected, so a foreign realm cannot replay a captured cur to impersonate
// a member. op names the operation in the panic message.
func (a *Authority) Assert(_ int, rlm realm, op string) {
	if !rlm.IsCurrent() {
		panic(op + ": rlm is not the caller's live realm")
	}
	if caller := rlm.Previous().Address(); !a.members.Has(caller) {
		panic(ufmt.Sprintf("%s: caller %s is not a member of the authority", op, caller))
	}
}

// AddMember adds addr. Members only, except for the test-framework bootstrap
// described on the bootstrapped field.
func (a *Authority) AddMember(_ int, rlm realm, addr address) {
	if addr == "" {
		panic("authority: empty address")
	}
	if a.bootstrapped {
		a.Assert(0, rlm, "add_authority_member")
	}
	a.bootstrapped = true
	a.members.Add(addr)
}

// RemoveMember removes addr. The last member cannot be removed: an empty
// authority would leave the realm without anyone able to administer it.
func (a *Authority) RemoveMember(_ int, rlm realm, addr address) {
	a.Assert(0, rlm, "remove_authority_member")
	if !a.members.Has(addr) {
		panic("authority: " + string(addr) + " is not a member")
	}
	if a.members.Size() == 1 {
		panic("authority: cannot remove the last member")
	}
	a.members.Remove(addr)
}

// IsMember reports whether addr is a member.
func (a *Authority) IsMember(addr address) bool {
	return a.members.Has(addr)
}

// Members returns the members in address order.
func (a *Authority) Members() []address {
	var out []address
	a.members.Tree().Iterate("", "", func(k string, _ any) bool {
		out = append(out, address(k))
		return false
	})
	return out
}
