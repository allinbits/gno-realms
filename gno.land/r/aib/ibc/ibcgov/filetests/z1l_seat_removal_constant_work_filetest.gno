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

// many is how many Ethereum clients the departing guardian flagged.
const many = 40

// Removing or replacing a guardian is constant work, however many flags its
// key set (Codex round 12 #2): the seat's generation grows, its flags stop
// counting at once (the hold, the functions, the payouts epoch), and their
// entries are pruned later in bounded batches that anyone may run.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g0)+",1:"+string(g1))))
	var clients []string
	for i := 0; i < many; i++ {
		c := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
		flagAs(cur, g0, c, ibcgov.FnSends, "")
		clients = append(clients, c)
	}
	flagAs(cur, g0, route, ibcgov.FnPayouts, "")
	flagAs(cur, g1, route, ibcgov.FnSends, "")
	epoch, _ := ibcgov.PayoutsEpoch(route)
	println("hold:", ibcgov.Held(), "| payouts flagged:", ibcgov.Flagged(route, ibcgov.FnPayouts), "| epoch", epoch)

	// Vacating seat 0 applies at once.
	govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"))
	epoch, _ = ibcgov.PayoutsEpoch(route)
	println("after the removal: payouts flagged:", ibcgov.Flagged(route, ibcgov.FnPayouts), "| a client flagged:", ibcgov.Flagged(clients[7], ibcgov.FnSends),
		"| epoch", epoch, "| hold ending:", ibcgov.Held())
	advance(25 * time.Hour)
	println("a day later, hold:", ibcgov.Held())

	// A new key in seat 0 starts with no flag.
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g2))))
	println("seat 0:", ibcgov.Seat(0) == g2, "| a client flagged:", ibcgov.Flagged(clients[3], ibcgov.FnSends))

	// The stale entries go in bounded batches; the epoch stays as read.
	removed, calls := 0, 0
	for {
		n := ibcgov.PruneFlags(cross(cur), 16)
		removed += n
		calls++
		if n == 0 && calls > 3 {
			break
		}
	}
	epoch2, _ := ibcgov.PayoutsEpoch(route)
	println("pruned:", removed, "| epoch unchanged:", epoch2 == epoch, "| route flags:", len(ibcgov.Flags(route)))
}

// Output:
// hold: true | payouts flagged: true | epoch 0
// after the removal: payouts flagged: false | a client flagged: false | epoch 1 | hold ending: true
// a day later, hold: false
// seat 0: true | a client flagged: false
// pruned: 41 | epoch unchanged: true | route flags: 1
