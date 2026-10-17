// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	g0        = testutils.TestAddress("guardian-0")
	g1        = testutils.TestAddress("guardian-1")
	g2        = testutils.TestAddress("guardian-2")
	g3        = testutils.TestAddress("guardian-3")
	w4        = testutils.TestAddress("watch-4")
	w5        = testutils.TestAddress("watch-5")
	g3new     = testutils.TestAddress("guardian-3-new")
)

// advance moves the block time on by d.
func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

// govern makes a decision as the governor and returns its number.
func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

// execute applies a queued decision once its 7 days have passed.
func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

// setupRoute creates an Ethereum client, installs transfer impl/v1 and
// enrolls the client as a route, every step a governor decision.
func setupRoute(cur realm) string {
	clientID := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector), bridge)))
	advance(7*24*time.Hour + time.Second) // keeps the timeline of the goldens
	return clientID
}

// flagAs sets a flag as the key of a seat.
func flagAs(cur realm, who address, route, fn, keys string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.SetFlag(cross(cur), route, fn, keys)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func clearAs(cur realm, who address, route, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.ClearFlag(cross(cur), route, fn)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// Guardian seats, flags and holds on gno.land (ADR pr6375 §7.4, R10).
func main(cur realm) {
	route := setupRoute(cur)

	// Seats: additions wait 7 days; at most two guardian seats a decision.
	println("three guardians:", revive(func() {
		govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g0)+",1:"+string(g1)+",2:"+string(g2)))
	}))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g0)+",1:"+string(g1))))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "2:"+string(g2)+",3:"+string(g3)+",4:"+string(w4)+",5:"+string(w5))))
	println("seats:", ibcgov.Seat(0) == g0, ibcgov.Seat(3) == g3, ibcgov.Seat(5) == w5, ibcgov.SeatOf(w4))
	println("same key twice:", revive(func() { govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "1:"+string(g0))) }))

	// Flags: anyone not in a seat is refused; only a guardian's payouts flag
	// names packets.
	println("stranger:", revive(func() { flagAs(cur, collector, route, ibcgov.FnPayouts, "") }))
	println("watch key naming:", revive(func() { flagAs(cur, w4, route, ibcgov.FnPayouts, route+"/00000000000000000007") }))
	println("bad function:", revive(func() { flagAs(cur, g0, route, "everything", "") }))
	println("unknown route:", revive(func() { flagAs(cur, g0, "ethereum-9", ibcgov.FnSends, "") }))

	// One guardian flag pauses the function, no hold. A watch key's flag
	// never counts toward a hold.
	flagAs(cur, g0, route, ibcgov.FnPayouts, route+"/00000000000000000007")
	flagAs(cur, w4, route, ibcgov.FnCredits, "")
	println("payouts:", ibcgov.Flagged(route, ibcgov.FnPayouts), "credits:", ibcgov.Flagged(route, ibcgov.FnCredits),
		"sends:", ibcgov.Flagged(route, ibcgov.FnSends), "held:", ibcgov.Held())
	println("named:", ibcgov.NamedSuspect(route, route+"/00000000000000000007"), ibcgov.NamedSuspect(route, route+"/00000000000000000008"))

	// A second guardian makes a hold: queued decisions are deferred and
	// unpauses are spent.
	queued := govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("relayer"))))
	flagAs(cur, g1, route, ibcgov.FnSends, "")
	println("held:", ibcgov.Held())
	advance(7*24*time.Hour + time.Second)
	println("execute under a hold:", revive(func() { ibcgov.Execute(cross(cur), queued) }))
	unpause := govern(cur, ibcgov.NewUnpauseRouteRequest(cross(cur), route, "sends"))
	d, _ := ibcgov.Decision(unpause)
	println("unpause under a hold:", d.State(), "-", d.Note, "- sends still flagged:", ibcgov.Flagged(route, ibcgov.FnSends))

	// Below two guardian flags the hold lingers 24 hours, then ends.
	clearAs(cur, g1, route, ibcgov.FnSends)
	println("held right after:", ibcgov.Held())
	advance(23 * time.Hour)
	println("execute 23h later:", revive(func() { ibcgov.Execute(cross(cur), queued) }))
	advance(time.Hour)
	ibcgov.Execute(cross(cur), queued)
	println("held a day later:", ibcgov.Held(), "relayers:", len(core.Relayers()))

	// Clearing a payouts flag starts a new payouts epoch (the meters restart
	// empty).
	e0, _ := ibcgov.PayoutsEpoch(route)
	clearAs(cur, g0, route, ibcgov.FnPayouts)
	e1, _ := ibcgov.PayoutsEpoch(route)
	println("payouts epoch:", e0, "->", e1)
	println("clear twice:", revive(func() { clearAs(cur, g0, route, ibcgov.FnPayouts) }))

	// An unpause decision clears every seat's flags of a function at once.
	flagAs(cur, g2, route, ibcgov.FnRefunds, "")
	unpause = govern(cur, ibcgov.NewUnpauseRouteRequest(cross(cur), route, "credits,refunds"))
	d, _ = ibcgov.Decision(unpause)
	println("unpause:", d.State(), "-", d.Note, "- credits:", ibcgov.Flagged(route, ibcgov.FnCredits), "refunds:", ibcgov.Flagged(route, ibcgov.FnRefunds))

	// A guardian replacement lands through a hold, no sooner than day 21 of it.
	flagAs(cur, g0, route, ibcgov.FnSends, "")
	flagAs(cur, g1, route, ibcgov.FnSends, "")
	since := ibcgov.HoldSince()
	replace := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "3:"+string(g3new)))
	advance(7*24*time.Hour + time.Second)
	println("replacement on day 7 of the hold:", revive(func() { ibcgov.Execute(cross(cur), replace) }))
	advance(time.Duration(since+21*86400-testing.GetContext().Time.Unix()) * time.Second)
	ibcgov.Execute(cross(cur), replace)
	println("replacement on day 21:", ibcgov.Seat(3) == g3new, "still held:", ibcgov.Held())

	// Vacating a seat applies at once and clears the seat's flags.
	govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "1:"))
	println("seat 1:", ibcgov.Seat(1), "sends flags:", ibcgov.Flags(route))
	println(ibcgov.Render(""))
}

// Output:
// three guardians: ibcgov: a decision changes at most two guardian seats
// seats: true true true 4
// same key twice: ibcgov: g1va6kzunyd9skutfsta047h6lta047h6lczd94n would hold seats 0 and 1
// stranger: ibcgov: not a guardian or a watch key: g1vdhkcmr9vd6x7ujlta047h6lta047h6lsp3m50
// watch key naming: ibcgov: only a guardian's payouts flag names packets
// bad function: ibcgov: the function is sends, credits, payouts or refunds, not everything
// unknown route: ibcgov: no route or Ethereum client ethereum-9
// payouts: true credits: true sends: false held: false
// named: true false
// held: true
// execute under a hold: ibcgov: decision 4 is deferred: a guardian hold stands since 1236987094
// unpause under a hold: spent - spent: a guardian hold stands, which spends every unpause - sends still flagged: true
// held right after: true
// execute 23h later: ibcgov: decision 4 is deferred: a guardian hold stands since 1236987094
// held a day later: false relayers: 1
// payouts epoch: 0 -> 1
// clear twice: ibcgov: no such flag of yours
// unpause: applied - cleared 2 flags - credits: false refunds: false
// replacement on day 7 of the hold: ibcgov: decision 7 is deferred: a guardian hold stands since 1237678295
// replacement on day 21: true still held: true
// seat 1:  sends flags: slice[("sends seat 0 at 1237678295" string)]
// # IBC governance
//
// - governor: g1d93xxem0wckkwmmkv4exummjta047h6lhqp9y5 (until the yield) — it alone decides, by Govern from its own key, and gno.land/r/gov/dao's proposals are refused
// - clock factor 1 (1 on mainnet; a devnet build is compiled with 8): the 7-day delay is 604800 s and the 14-day deadline 1209600 s of block time
// - governance channel: not bound
// - **guardian hold** since 1237678295: queued decisions are deferred, unpauses are spent
//
// ## Seats
//
// - 0 (guardian): g1va6kzunyd9skutfsta047h6lta047h6lczd94n
// - 1 (guardian): empty
// - 2 (guardian): g1va6kzunyd9skutfjta047h6lta047h6l2w3lun
// - 3 (guardian): g1va6kzunyd9skutfn94hx2a6lta047h6l562e9h
// - 4 (watch key): g1washgcmg95697h6lta047h6lta047h6l726ltc
// - 5 (watch key): g1washgcmg95647h6lta047h6lta047h6lpq3k32
//
// ## Routes
//
// - ethereum\-1 (payouts epoch 1)
//   - flag: sends seat 0 at 1237678295
//
// ## Decisions
//
// ### set seats
//
// pending: none
//
// executed:
// - #8 applied: set seats 1= (recorded 1239492695, applied 1239492695) — seats 1
// - #7 applied: set seats 3=g1va6kzunyd9skutfn94hx2a6lta047h6l562e9h (recorded 1237678295, applied 1239492695) — seats 3
// - #3 applied: set seats 2=g1va6kzunyd9skutfjta047h6lta047h6l2w3lun,3=g1va6kzunyd9skutfnta047h6lta047h6lrgljvn,4=g1washgcmg95697h6lta047h6lta047h6l726ltc,5=g1washgcmg95647h6lta047h6lta047h6lpq3k32 (recorded 1236382293, applied 1236987094) — seats 2,3,4,5
// - #2 applied: set seats 0=g1va6kzunyd9skutfsta047h6lta047h6lczd94n,1=g1va6kzunyd9skutf3ta047h6lta047h6l3yrg9n (recorded 1235777492, applied 1236382293) — seats 0,1
//
// ### unpause route
//
// pending: none
//
// executed:
// - #6 applied: unpause credits,refunds on route ethereum\-1 (recorded 1237678295, applied 1237678295) — cleared 2 flags
// - #5 spent: unpause sends on route ethereum\-1 (recorded 1237591895) — spent: a guardian hold stands, which spends every unpause
//
// ### core add relayer
//
// pending: none
//
// executed:
// - #4 applied: core: add relayer g1wfjkcctev4e97h6lta047h6lta047h6lyh98u9 (recorded 1236987094, applied 1237678295) — core add relayer
//
// ### enroll route
//
// pending: none
//
// executed:
// - #1 applied: enroll route ethereum\-1 with fee collector g1vdhkcmr9vd6x7ujlta047h6lta047h6lsp3m50 and bridge contracts router 0x00000000000000000000000000000000000b0001, ICS20 transfer 0x00000000000000000000000000000000000b0002, IBCAdmin 0x00000000000000000000000000000000000b0003 (recorded 1234567890, applied 1235172691) — enroll
