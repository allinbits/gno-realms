// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var collector = testutils.TestAddress("collector")

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
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", clientID, string(collector), bridge, "", "", 10_000)))
	advance(7*24*time.Hour + time.Second) // the separate enrollment's delay, kept so the timeline stays
	return clientID
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.Kind + ": " + d.State()
}

// Whether a decision applies at once or waits 7 days is decided against the
// live state when it is recorded, not when its request was built: a request
// built as a lowering that has become a raising waits.
func main(cur realm) {
	route := setupRoute(cur)
	// Launch floor 10000, then raised to 50000.
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 50_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))

	a := ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 40_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee") // a lowering when built
	b := govern(cur, ibcgov.NewSetDenomRequest(cross(cur), route, "ugnot", "unescrow", 20_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee"))
	println(decided(b))
	println("A, now a raising from 20000:", decided(govern(cur, a)))

	// Relayer removals: two requests built while two relayers are listed.
	execute(cur, govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("r1")))))
	execute(cur, govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(testutils.TestAddress("r2")))))
	r1 := ibcgov.NewCoreRemoveRelayerRequest(cross(cur), string(testutils.TestAddress("r1")))
	r2 := ibcgov.NewCoreRemoveRelayerRequest(cross(cur), string(testutils.TestAddress("r2")))
	println(decided(govern(cur, r1)), "| the last one:", decided(govern(cur, r2)), "| listed:", len(core.Relayers()))

	// ibcgov never leaves the authorities.
	println(revive(func() {
		govern(cur, ibcgov.NewCoreRemoveMemberRequest(cross(cur), chain.PackageAddress(ibcgov.PkgPath).String()))
	}))
	println(revive(func() {
		govern(cur, ibcgov.NewTransferRemoveMemberRequest(cross(cur), chain.PackageAddress(ibcgov.PkgPath).String()))
	}))
}

// Output:
// set denom: applied
// A, now a raising from 20000: set denom: pending
// core remove relayer: applied | the last one: core remove relayer: pending | listed: 1
// ibcgov: this realm stays a member of the core's authority
// ibcgov: this realm stays a member of the transfer app's authority
