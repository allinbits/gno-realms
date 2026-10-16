// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/runtime/unsafe"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
	"gno.land/r/gov/dao"
	daoinit "gno.land/r/gov/dao/init/v0"
)

var member address = unsafe.OriginCaller()

// advance moves the block time on by d.
func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

// The governor decides alone until it yields (ADR pr6375 §7.7): through the
// same builders, checks and delays as GovDAO; GovDAO's proposals are refused
// until the yield, after which only they decide.
func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), member)
	gov := ibcgov.Governor()
	println("governor:", gov, "GovDAO governs:", ibcgov.GovDAOGoverns())

	// Somebody else cannot Govern, nor yield.
	testing.SetRealm(testing.NewUserRealm(member))
	println("stranger governs:", revive(func() { ibcgov.Govern(cross(cur), ibcgov.NewCorePauseRequest(cross(cur))) }))
	testing.SetRealm(testing.NewUserRealm(member))
	println("stranger yields:", revive(func() { ibcgov.Yield(cross(cur)) }))

	// A GovDAO proposal before the yield: created and voted, but its execution
	// is refused by the closure (it panics, so the proposal stays executable).
	testing.SetOriginCaller(member)
	testing.SetRealm(testing.NewUserRealm(member))
	pid := dao.MustCreateProposal(cross(cur), ibcgov.NewCorePauseRequest(cross(cur)).Proposal())
	testing.SetRealm(testing.NewUserRealm(member))
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))
	testing.SetRealm(testing.NewUserRealm(member))
	println("GovDAO before the yield:", revive(func() { dao.ExecuteProposal(cross(cur), pid) }))
	println("paused:", core.Paused())

	// The governor: an at-once decision (pause) and a queued one (a relayer).
	testing.SetRealm(testing.NewUserRealm(gov))
	ibcgov.Govern(cross(cur), ibcgov.NewCorePauseRequest(cross(cur)))
	println("paused:", core.Paused())
	testing.SetRealm(testing.NewUserRealm(gov))
	ibcgov.Govern(cross(cur), ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("relayer"))))
	id := ibcgov.LastDecision()
	d, _ := ibcgov.Decision(id)
	println("decision", id, d.Kind, d.State(), "due in", d.Due-d.Recorded, "s")
	println("execute early:", revive(func() { ibcgov.Execute(cross(cur), id) }))
	advance(7 * 24 * time.Hour)
	ibcgov.Execute(cross(cur), id)
	d, _ = ibcgov.Decision(id)
	println("after 7 days:", d.State(), "relayers:", core.Relayers())
	println("execute twice:", revive(func() { ibcgov.Execute(cross(cur), id) }))

	// A queued decision is cancelled by a cancel decision.
	testing.SetRealm(testing.NewUserRealm(gov))
	ibcgov.Govern(cross(cur), ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("relayer1"))))
	queued := ibcgov.LastDecision()
	testing.SetRealm(testing.NewUserRealm(gov))
	ibcgov.Govern(cross(cur), ibcgov.NewCancelRequest(cross(cur), queued))
	d, _ = ibcgov.Decision(queued)
	println("cancelled:", d.State())
	advance(8 * 24 * time.Hour)
	println("execute cancelled:", revive(func() { ibcgov.Execute(cross(cur), queued) }))

	// A request older than 14 days is past its deadline.
	testing.SetRealm(testing.NewUserRealm(gov))
	stale := ibcgov.NewCoreUnpauseRequest(cross(cur))
	advance(15 * 24 * time.Hour)
	testing.SetRealm(testing.NewUserRealm(gov))
	println("stale:", revive(func() { ibcgov.Govern(cross(cur), stale) }))

	// The yield, once; Govern closes, GovDAO decides.
	testing.SetRealm(testing.NewUserRealm(gov))
	ibcgov.Yield(cross(cur))
	println("GovDAO governs:", ibcgov.GovDAOGoverns(), "yielded at", ibcgov.Yielded() > 0)
	testing.SetRealm(testing.NewUserRealm(gov))
	println("yield again:", revive(func() { ibcgov.Yield(cross(cur)) }))
	testing.SetRealm(testing.NewUserRealm(gov))
	println("governor after the yield:", revive(func() { ibcgov.Govern(cross(cur), ibcgov.NewCoreUnpauseRequest(cross(cur))) }))

	testing.SetRealm(testing.NewUserRealm(member))
	pid2 := dao.MustCreateProposal(cross(cur), ibcgov.NewCoreUnpauseRequest(cross(cur)).Proposal())
	testing.SetRealm(testing.NewUserRealm(member))
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid2))
	testing.SetRealm(testing.NewUserRealm(member))
	println("GovDAO after the yield:", dao.ExecuteProposal(cross(cur), pid2), "paused:", core.Paused())
	println(ibcgov.Render(""))
}

// Output:
// governor: g1d93xxem0wckkwmmkv4exummjta047h6lhqp9y5 GovDAO governs: false
// stranger governs: ibcgov: until the governor yields, g1d93xxem0wckkwmmkv4exummjta047h6lhqp9y5 alone decides, by Govern from its own key: not g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm (a GovDAO proposal is refused until the yield)
// stranger yields: ibcgov: only the governor g1d93xxem0wckkwmmkv4exummjta047h6lhqp9y5 yields, not g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
// GovDAO before the yield: ibcgov: until the governor yields, g1d93xxem0wckkwmmkv4exummjta047h6lhqp9y5 alone decides, by Govern from its own key: not gno.land/r/gov/dao (a GovDAO proposal is refused until the yield)
// paused: false
// paused: true
// decision 2 core add relayer pending due in 604800 s
// execute early: ibcgov: decision 2 is due at 1235172690, not before
// after 7 days: applied relayers: slice[("g1wfjkcctev4e97h6lta047h6lta047h6lyh98u9" .uverse.address)]
// execute twice: ibcgov: decision 2 is applied, not pending
// cancelled: cancelled
// execute cancelled: ibcgov: decision 3 is cancelled, not pending
// stale: ibcgov: the proposal is past its 14-day deadline (made at 1235863890, now 1237159890)
// GovDAO governs: true yielded at true
// yield again: ibcgov: the governor yielded at height 123 already
// governor after the yield: ibcgov: the governor yielded at height 123, gno.land/r/gov/dao governs since: a decision is a GovDAO proposal, never Govern
// GovDAO after the yield: true paused: false
// # IBC governance
//
// - governor: gno.land/r/gov/dao since height 123 (g1d93xxem0wckkwmmkv4exummjta047h6lhqp9y5 yielded)
// - clock factor 1 (1 on mainnet; a devnet build is compiled with 8): the 7-day delay is 604800 s and the 14-day deadline 1209600 s of block time
// - governance channel: not bound
//
// ## Seats
//
// - 0 (guardian): empty
// - 1 (guardian): empty
// - 2 (guardian): empty
// - 3 (guardian): empty
// - 4 (watch key): empty
// - 5 (watch key): empty
//
// ## Routes
//
// No route enrolled.
//
// ## Decisions
//
// ### core unpause
//
// pending: none
//
// executed:
// - #5 applied: core: unpause the packet path (recorded 1237159890, applied 1237159890) — core unpaused
//
// ### cancel
//
// pending: none
//
// executed:
// - #4 applied: cancel decision 3 \(core add relayer\) (recorded 1235172690, applied 1235172690) — cancelled decision 3
//
// ### core add relayer
//
// pending: none
//
// executed:
// - #3 cancelled: core: add relayer g1wfjkcctev4erzh6lta047h6lta047h6l6azkjj (recorded 1235172690, cancelled 1235172690) — queued 7 days
// - #2 applied: core: add relayer g1wfjkcctev4e97h6lta047h6lta047h6lyh98u9 (recorded 1234567890, applied 1235172690) — core add relayer
//
// ### core pause
//
// pending: none
//
// executed:
// - #1 applied: core: pause the packet path (recorded 1234567890, applied 1234567890) — core pause
