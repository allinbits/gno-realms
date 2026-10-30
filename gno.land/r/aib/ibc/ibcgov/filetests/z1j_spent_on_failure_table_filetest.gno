// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

func advance() {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(7*24*time.Hour + time.Second)
	testing.SetContext(ctx)
}

func state(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// Every governed decision whose execution would fail on the live state is
// refused and spent, never aborted and left pending (Codex round 4, class B).
// Each row: a decision fails because the state moved, the state moves back,
// and the old approval is refused. z1e (app approvals), z1f (recovery,
// migration), z1h and z1i (implementation switches), z2e (Ethereum-bound
// sends) and transfer's z9m (route operations without the controls) cover
// the other kinds.
func main(cur realm) {
	member := testutils.TestAddress("member")
	blocked := testutils.TestAddress("blocked")

	// core add member: a second decision adding the same member.
	a1 := govern(cur, ibcgov.NewCoreAddMemberRequest(cross(cur), string(member)))
	a2 := govern(cur, ibcgov.NewCoreAddMemberRequest(cross(cur), string(member)))
	advance()
	ibcgov.Execute(cross(cur), a1)
	ibcgov.Execute(cross(cur), a2)
	println("core add member twice:", state(a2))
	govern(cur, ibcgov.NewCoreRemoveMemberRequest(cross(cur), string(member)))
	println("  retry once removed:", revive(func() { ibcgov.Execute(cross(cur), a2) }), "| member:", core.IsAuthorityMember(member))

	// transfer add member, the same.
	t1 := govern(cur, ibcgov.NewTransferAddMemberRequest(cross(cur), string(member)))
	t2 := govern(cur, ibcgov.NewTransferAddMemberRequest(cross(cur), string(member)))
	advance()
	ibcgov.Execute(cross(cur), t1)
	ibcgov.Execute(cross(cur), t2)
	println("transfer add member twice:", state(t2))
	govern(cur, ibcgov.NewTransferRemoveMemberRequest(cross(cur), string(member)))
	println("  retry once removed:", revive(func() { ibcgov.Execute(cross(cur), t2) }), "| member:", transfer.IsAuthorityMember(member))

	// transfer unblock: two decisions unblocking the same address.
	govern(cur, ibcgov.NewTransferBlockRequest(cross(cur), string(blocked)))
	u1 := govern(cur, ibcgov.NewTransferUnblockRequest(cross(cur), string(blocked)))
	u2 := govern(cur, ibcgov.NewTransferUnblockRequest(cross(cur), string(blocked)))
	advance()
	ibcgov.Execute(cross(cur), u1)
	ibcgov.Execute(cross(cur), u2)
	println("transfer unblock twice:", state(u2))
	govern(cur, ibcgov.NewTransferBlockRequest(cross(cur), string(blocked)))
	println("  retry once blocked again:", revive(func() { ibcgov.Execute(cross(cur), u2) }), "| blocked:", transfer.IsBlocked(blocked))

	// core unpause (at once): spent when the core is not paused.
	un := govern(cur, ibcgov.NewCoreUnpauseRequest(cross(cur)))
	println("core unpause, not paused:", state(un))
	govern(cur, ibcgov.NewCorePauseRequest(cross(cur)))
	println("  retry once paused:", revive(func() { ibcgov.Execute(cross(cur), un) }), "| paused:", core.Paused())

	// core pause (at once): spent when paused already.
	p2 := govern(cur, ibcgov.NewCorePauseRequest(cross(cur)))
	println("core pause, paused already:", state(p2))
}

// Output:
// core add member twice: spent - spent: g1d4jk6cn9wf047h6lta047h6lta047h6l2v6vjt is a member already
//   retry once removed: ibcgov: decision 2 is spent, not pending | member: false
// transfer add member twice: spent - spent: g1d4jk6cn9wf047h6lta047h6lta047h6l2v6vjt is a member already
//   retry once removed: ibcgov: decision 5 is spent, not pending | member: false
// transfer unblock twice: spent - spent: g1vfkx7cmtv4j97h6lta047h6lta047h6lyw2wka is not blocked
//   retry once blocked again: ibcgov: decision 9 is spent, not pending | blocked: true
// core unpause, not paused: spent - spent: the core is not paused
//   retry once paused: ibcgov: decision 11 is spent, not pending | paused: true
// core pause, paused already: spent - spent: the core is paused already
