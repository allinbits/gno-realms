// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
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
	bob       = testutils.TestAddress("bob")
)

const weth = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"

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

// recv delivers a packet from Ethereum to the transfer app as the core does
// after verifying its proof.
func recv(cur realm, route string, seq uint64, denom, receiver string, amount int64) {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatInt(amount, 10), "0x5f67a5398d91087d1b37a8a43436196a7830867f", receiver, "")
	bz, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	if res := app.OnRecvPacket(cross(cur), "client-0", route, seq, payload); res.Status != types.PacketStatus_Success {
		panic("receive refused")
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func claim(cur realm, route, denom string) int {
	testing.SetRealm(testing.NewUserRealm(bob)) // anyone
	n := transfer.Claim(cross(cur), route, denom, 20)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return n
}

// meters is what the route's bridge meter and bob's meter of denom hold now,
// under the payouts epoch ibcgov reports.
func meters(route, denom string) (int64, int64) {
	epoch, at := ibcgov.PayoutsEpoch(route)
	return transfer.ExtView("controls").(controls.Reader).Meters(route, denom, bob, time.Now().Unix(), epoch, at, 0)
}

func paid(route string) int64 {
	c, _ := transfer.ExtView("controls").(controls.Reader).Claim(route, controls.PacketKey(route, 1))
	return c.Paid
}

// many is how many Ethereum clients the departing guardian flagged.
const many = 40

// Removing or replacing a guardian is constant work, however many flags its
// key set (Codex round 12 #2): the seat's generation grows, its flags stop
// counting at once (the hold, the functions, the payouts epoch), and their
// entries are pruned later in bounded batches that anyone may run.
//
// The payouts flag of a removed key counts as cleared when the key left
// (T1), not when the seat is next filled (T2), before and after its entry is
// pruned (Codex round 14): the meters refill from T1, so a claim right after
// T2 pays.
func main(cur realm) {
	route := setupRoute(cur)
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "")))
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g0)+",1:"+string(g1))))
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", route)).IBCDenom()
	recv(cur, route, 1, weth, bob.String(), 3_000)
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

	// Vacating seat 0 waits, through the hold, until day 21 of it.
	since := ibcgov.HoldSince()
	vacate := govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"))
	advance(time.Duration(since+21*86400-testing.GetContext().Time.Unix()) * time.Second)
	ibcgov.Execute(cross(cur), vacate)
	t1 := time.Now().Unix()
	epoch, _ = ibcgov.PayoutsEpoch(route)
	println("after the removal: payouts flagged:", ibcgov.Flagged(route, ibcgov.FnPayouts), "| a client flagged:", ibcgov.Flagged(clients[7], ibcgov.FnSends),
		"| epoch", epoch, "| hold ending:", ibcgov.Held())
	advance(25 * time.Hour)
	println("a day later, hold:", ibcgov.Held())

	// A new key in seat 0 starts with no flag.
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(g2))))
	t2 := time.Now().Unix()
	println("seat 0:", ibcgov.Seat(0) == g2, "| a client flagged:", ibcgov.Flagged(clients[3], ibcgov.FnSends))

	// Before pruning: cleared as of T1, a day's refill since, and paid.
	_, at := ibcgov.PayoutsEpoch(route)
	bridgeLevel, bobLevel := meters(route, voucher)
	println("before pruning: cleared at T1:", at == t1, "| at T2:", at == t2, "| meters", bridgeLevel, bobLevel)
	println("claim at T2:", claim(cur, route, voucher), "| bob paid", paid(route))

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
	epoch2, at2 := ibcgov.PayoutsEpoch(route)
	println("pruned:", removed, "| epoch unchanged:", epoch2 == epoch, "| route flags:", len(ibcgov.Flags(route)))

	// After pruning: still cleared as of T1; the meters refill on from the
	// claim, half a day's worth of bob's quarter in 12 hours.
	bridgeLevel, bobLevel = meters(route, voucher)
	println("after pruning: cleared at T1:", at2 == t1, "| meters", bridgeLevel, bobLevel)
	advance(12 * time.Hour)
	bridgeLevel, bobLevel = meters(route, voucher)
	println("12 hours later: meters", bridgeLevel, bobLevel, "| claim:", claim(cur, route, voucher), "| bob paid", paid(route))
}

// Output:
// hold: true | payouts flagged: true | epoch 0
// after the removal: payouts flagged: false | a client flagged: false | epoch 1 | hold ending: true
// a day later, hold: false
// seat 0: true | a client flagged: false
// before pruning: cleared at T1: true | at T2: false | meters 4000 1000
// claim at T2: 1 | bob paid 1000
// pruned: 41 | epoch unchanged: true | route flags: 1
// after pruning: cleared at T1: true | meters 3000 0
// 12 hours later: meters 4000 500 | claim: 1 | bob paid 1500
