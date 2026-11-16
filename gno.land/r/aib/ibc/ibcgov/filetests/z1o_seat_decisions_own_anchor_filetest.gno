// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

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

// Each recording of a seat-change Request has its own hold anchor (code
// review r60 #1): one Request governed twice makes D1 and D2. A hold from
// day 0 defers D1 on day 7, anchoring it; D1 is cancelled; the hold ends
// and another starts on day 20. D2, first deferred on day 21, is anchored
// at the new hold, so it does not land then: it never inherits D1's anchor.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g0)+",1:"+string(g1))))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "2:"+string(g2)+",3:"+string(g3))))
	flagAs(cur, g0, route, ibcgov.FnSends, "")
	flagAs(cur, g1, route, ibcgov.FnSends, "")
	first := ibcgov.HoldSince()
	req := ibcgov.NewSetSeatsRequest(cross(cur), "3:"+string(g3new))
	d1 := govern(cur, req)
	d2 := govern(cur, req)
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), d1) // deferred: D1 anchored at day 0
	govern(cur, ibcgov.NewCancelRequest(cross(cur), d1))
	at := func(day int64) {
		advance(time.Duration(first+day*86400-testing.GetContext().Time.Unix()) * time.Second)
	}
	at(19)
	clearAs(cur, g1, route, ibcgov.FnSends)
	at(20)
	advance(time.Second)
	flagAs(cur, g1, route, ibcgov.FnSends, "")
	println("a new hold since day 20:", ibcgov.Held(), ibcgov.HoldSince() > first)
	at(21)
	ibcgov.Execute(cross(cur), d2) // D2's first deferral: anchored at day 20
	d, _ := ibcgov.Decision(d2)
	println("D2 on day 21 of the first hold:", d.State(), "| seat 3 replaced:", ibcgov.Seat(3) == g3new)
	at(41)
	advance(time.Second)
	ibcgov.Execute(cross(cur), d2)
	d, _ = ibcgov.Decision(d2)
	println("D2 on day 21 of its own hold:", d.State(), "| seat 3 replaced:", ibcgov.Seat(3) == g3new)
}

// Output:
// a new hold since day 20: true true
// D2 on day 21 of the first hold: pending | seat 3 replaced: false
// D2 on day 21 of its own hold: applied | seat 3 replaced: true
