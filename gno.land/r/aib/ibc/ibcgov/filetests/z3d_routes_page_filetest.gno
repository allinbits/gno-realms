// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

var guardian = testutils.TestAddress("guardian")

func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

// route makes a provisional route record for a new client of chain id.
func route(cur realm, id uint64) {
	cs := ethtesting.ClientState()
	cs.ChainID = id
	c := core.CreateClient(cross(cur), cs, ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), c, [][]byte{{}}, "client-0")
	d := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), c, "0:"+string(guardian)))
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), d)
}

// page reports how many routes a home page shows, and its "more" line.
func page(path string) string {
	out := ibcgov.Render(path)
	more := "no more"
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "- more: ") {
			more = l
		}
	}
	return itoa(strings.Count(out, "\n### ethereum")) + " routes, " + more
}

func itoa(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	return itoa(n/10) + string(rune('0'+n%10))
}

// The home page shows 20 routes; a "more" link to the next page appears
// only when there is one, so it never leads to an empty page.
func main(cur realm) {
	for i := uint64(1); i <= 20; i++ {
		route(cur, i)
	}
	println("20 routes:", page(""))
	route(cur, 21)
	first := page("")
	println("21 routes:", first)
	_, link, _ := strings.Cut(first, "](:")
	println("next page:", page(strings.TrimSuffix(link, ")")))
}

// Output:
// 20 routes: 20 routes, no more
// 21 routes: 20 routes, - more: [routes after ethereum\-8](:?from=ethereum-8)
// next page: 1 routes, no more
