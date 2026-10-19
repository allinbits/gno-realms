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

// A vacancy removes only the tenure it was requested against (code review
// r63 #1): recorded while A holds seat 2, it is still pending when the seat
// goes to B and back to A, who flags again; executed then, it is spent
// (the seat's generation moved on), and A keeps the seat and its flag.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g0)+",1:"+string(g1))))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "2:"+string(g2)+",3:"+string(g3))))
	vacancy := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "2:"))
	toB := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "2:"+string(g3new)))
	execute(cur, toB)
	println("seat 2 is B:", ibcgov.Seat(2) == g3new)
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "2:"+string(g2))))
	println("seat 2 is A again:", ibcgov.Seat(2) == g2)
	flagAs(cur, g2, route, ibcgov.FnSends, "")
	ibcgov.Execute(cross(cur), vacancy)
	d, _ := ibcgov.Decision(vacancy)
	println("the stale vacancy:", d.State(), "-", d.Note)
	println("seat 2 kept by A:", ibcgov.Seat(2) == g2, "| its flag stands:", ibcgov.Flagged(route, ibcgov.FnSends))
}

// Output:
// seat 2 is B: true
// seat 2 is A again: true
// the stale vacancy: spent - spent: nothing to change
// seat 2 kept by A: true | its flag stands: true
