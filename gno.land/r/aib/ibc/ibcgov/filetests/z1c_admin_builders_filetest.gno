// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/testutils/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v1"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	r1        = testutils.TestAddress("relayer-1")
	r2        = testutils.TestAddress("relayer-2")
	member    = testutils.TestAddress("member")
	blocked   = testutils.TestAddress("blocked")
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
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", clientID, string(collector), bridge, "", 10_000)))
	advance(7*24*time.Hour + time.Second) // the separate enrollment's delay, kept so the timeline stays
	return clientID
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.Kind + ": " + d.State()
}

// The builders of the core's and the transfer app's administration (ADR
// pr6375 R14): loosening queued 7 days, tightening at once.
func main(cur realm) {
	// Relayers: adding waits; removing is at once while another stays listed,
	// queued when it is the last one.
	execute(cur, govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(r1))))
	execute(cur, govern(cur, ibcgov.NewCoreAddRelayerRequest(cross(cur), string(r2))))
	println("relayers:", len(core.Relayers()))
	println(decided(govern(cur, ibcgov.NewCoreRemoveRelayerRequest(cross(cur), string(r1)))), "relayers:", len(core.Relayers()))
	last := govern(cur, ibcgov.NewCoreRemoveRelayerRequest(cross(cur), string(r2)))
	println(decided(last), "relayers:", len(core.Relayers()))
	execute(cur, last)
	println(decided(last), "relayers:", len(core.Relayers()))
	println("remove an unlisted relayer:", revive(func() { govern(cur, ibcgov.NewCoreRemoveRelayerRequest(cross(cur), string(r1))) }))

	// Apps: a pending registration is approved after 7 days, or rejected at once.
	app := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/third/party/app"))
	core.RegisterApp(cross(cur), "thirdparty", app)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/other/party/app"))
	core.RegisterApp(cross(cur), "otherparty", app)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	approve := govern(cur, ibcgov.NewCoreApproveAppRequest(cross(cur), "thirdparty", "gno.land/r/third/party/app"))
	println(decided(approve), "routed:", core.AppPkgPath("thirdparty"))
	execute(cur, approve)
	println(decided(approve), "routed:", core.AppPkgPath("thirdparty"))
	println(decided(govern(cur, ibcgov.NewCoreRejectAppRequest(cross(cur), "otherparty", "gno.land/r/other/party/app"))),
		"pending:", core.IsAppPending("otherparty", "gno.land/r/other/party/app"))

	// Pausing an app is at once; so is unpausing (no hold stands).
	println(decided(govern(cur, ibcgov.NewCorePauseAppRequest(cross(cur), "thirdparty"))), core.IsAppPaused("thirdparty"))
	println(decided(govern(cur, ibcgov.NewCoreUnpauseAppRequest(cross(cur), "thirdparty"))), core.IsAppPaused("thirdparty"))
	println("unpause an app that is not paused:", decided(govern(cur, ibcgov.NewCoreUnpauseAppRequest(cross(cur), "thirdparty"))))

	// The core's authority: adding waits, removing is at once.
	add := govern(cur, ibcgov.NewCoreAddMemberRequest(cross(cur), string(member)))
	execute(cur, add)
	println(decided(add), core.IsAuthorityMember(member))
	println(decided(govern(cur, ibcgov.NewCoreRemoveMemberRequest(cross(cur), string(member)))), core.IsAuthorityMember(member))

	// The transfer app: block at once, unblock after 7 days; members likewise.
	println(decided(govern(cur, ibcgov.NewTransferBlockRequest(cross(cur), string(blocked)))), transfer.IsBlocked(blocked))
	unblock := govern(cur, ibcgov.NewTransferUnblockRequest(cross(cur), string(blocked)))
	println(decided(unblock), transfer.IsBlocked(blocked))
	execute(cur, unblock)
	println(decided(unblock), transfer.IsBlocked(blocked))
	execute(cur, govern(cur, ibcgov.NewTransferAddMemberRequest(cross(cur), string(member))))
	println("transfer member:", transfer.IsAuthorityMember(member))
	govern(cur, ibcgov.NewTransferRemoveMemberRequest(cross(cur), string(member)))
	println("transfer member:", transfer.IsAuthorityMember(member))

	// Implementations: only a registered one, under the right namespace.
	println("unregistered:", revive(func() {
		govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v9"))
	}))
	println("wrong namespace:", revive(func() {
		govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v0"))
	}))

	// A client migration: the decision spells out the fork schedule.
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v1")))
	fp := ethtesting.ClientState().ForkParameters
	fp.Gloas = ethereum.Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 1_000_000}
	mig := govern(cur, ibcgov.NewMigrateClientRequest(cross(cur), client, "ethereum-fork-schedule", hex.EncodeToString(ethereum.EncodeForkParameters(fp))))
	d, _ := ibcgov.Decision(mig)
	println(d.Text)
	execute(cur, mig)
	println(decided(mig))
	println("unknown migration:", revive(func() { govern(cur, ibcgov.NewMigrateClientRequest(cross(cur), client, "nope", "")) }))
	println("recover an unknown client:", revive(func() { govern(cur, ibcgov.NewRecoverClientRequest(cross(cur), client, "ethereum-9")) }))
}

// Output:
// relayers: 2
// core remove relayer: applied relayers: 1
// core remove relayer: pending relayers: 1
// core remove relayer: applied relayers: 0
// remove an unlisted relayer: ibcgov: g1wfjkcctev4ez6v2lta047h6lta047h6lqtcrv8 is not a listed relayer
// core approve app: pending routed:
// core approve app: applied routed: gno.land/r/third/party/app
// core reject app: applied pending: false
// core pause app: applied true
// core unpause app: applied false
// unpause an app that is not paused: core unpause app: spent
// core add member: applied true
// core remove member: applied false
// transfer block: applied true
// transfer unblock: pending true
// transfer unblock: applied false
// transfer member: true
// transfer member: false
// unregistered: ibcgov: no implementation is registered at gno.land/r/aib/ibc/core/impl/v9
// wrong namespace: ibcgov: an implementation lives under gno.land/r/aib/ibc/core/impl/v<N>, not gno.land/r/aib/ibc/apps/transfer/impl/v0
// core: migrate client ethereum-1 to the fork schedule genesis=10000038@slot0,altair=20000038@0,bellatrix=30000038@0,capella=40000038@0,deneb=50000038@0,electra=60000038@0,fulu=70000038@1,gloas=80000038@1000000
// core migrate client: applied
// unknown migration: ibcgov: unknown migration nope
// recover an unknown client: ibcgov: unknown client
