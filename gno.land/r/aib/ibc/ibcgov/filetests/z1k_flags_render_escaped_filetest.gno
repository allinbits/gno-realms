// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"
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

// The guardian flags on the governance page are escaped as inline Markdown
// (Codex round 10 #5): suspect packet keys whose client part is Markdown or
// HTML show as written, inert.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g0))))
	flagAs(cur, g0, route, ibcgov.FnPayouts, "_evil_/00000000000000000001,<br>/00000000000000000002,[x]#h/00000000000000000003")
	for _, l := range strings.Split(ibcgov.Render(""), "\n") {
		if strings.Contains(l, "flag:") {
			println(l)
		}
	}
}

// Output:
//   - flag: payouts seat 0 at 1236382293 naming \_evil\_/00000000000000000001,\<br\>/00000000000000000002,\[x\]\#h/00000000000000000003
