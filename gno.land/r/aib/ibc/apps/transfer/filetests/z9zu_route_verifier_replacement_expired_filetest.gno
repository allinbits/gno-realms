// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	implv1 "gno.land/r/aib/ibc/core/impl/v1"
	"gno.land/r/aib/ibc/ibcgov"
)

const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var collector = testutils.TestAddress("collector")

func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

func setTime(t time.Time) {
	ctx := testing.GetContext()
	ctx.Time = t
	testing.SetContext(ctx)
}

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

func client(cur realm, cs ethereum.ClientState, cons ethereum.ConsensusState) string {
	id := core.CreateClient(cross(cur), cs, cons)
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	return id
}

const nextImpl = "gno.land/r/aib/ibc/core/impl/v1next"

// A verifier replacement converts an Expired client too (design review #6):
// a fork or a verifier defect that stops a client's updates can outlast its
// trusting window (about 9 days) before a conversion, prepared then recorded
// with two 7-day delays, lands. The conversion keeps the client Expired (and
// the slot from which it trusts consensus states); an ordinary governed
// recovery, with a substitute ahead of it, then makes it Active. A Frozen
// client is refused: its misbehaviour is resolved by a recovery first.
func main(cur realm) {
	stalled := client(cur, ethtesting.ClientState(), ethtesting.ConsensusState())
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), stalled, string(collector), bridge)))
	frozen := client(cur, ethtesting.ClientState(), ethtesting.ConsensusState())
	testing.SetRealm(testing.NewCodeRealm(nextImpl))
	core.RegisterImpl(cross(cur), func(s core.Store) core.Logic {
		return implv1.NewWithConversions(s, "v1-next",
			[]string{ethereum.Version, ethereum.Version, ethtesting.FreezingVersion},
			[]string{ethtesting.NextVersion, ethtesting.FreezingVersion, ethtesting.NextVersion},
			[]func(*ethereum.Retired) lightclient.Interface{ethtesting.ToNextVerifier, ethtesting.ToFreezingVerifier, ethtesting.ToNextVerifier})
	}, "v1-next", []string{"v0", "v1"})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), nextImpl)))
	execute(cur, govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), frozen, ethtesting.FreezingVersion)))

	// Both clients stall: one expires, the other freezes.
	setTime(time.Unix(int64(ethtesting.ClientState().GenesisTime)+5000, 0))
	println("stalled:", core.ClientStatus(stalled), core.VerifierVersion(stalled), "| frozen:", core.ClientStatus(frozen), core.VerifierVersion(frozen))

	expired := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), stalled, ethtesting.NextVersion))
	execute(cur, expired)
	println("replace the expired client's verifier:", decided(expired))
	println("after:", core.ClientStatus(stalled), core.VerifierVersion(stalled), core.ClientLatestHeight(stalled))
	refused := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), frozen, ethtesting.NextVersion))
	execute(cur, refused)
	println("replace the frozen client's verifier:", decided(refused), "| still", core.VerifierVersion(frozen))

	// The ordinary recovery follows, with a substitute ahead of the client.
	cs := ethtesting.ClientState()
	cs.LatestSlot, cs.LatestExecutionBlockNumber = 5_000_000, 5_000_000
	cons := ethtesting.ConsensusState()
	cons.Slot = 5_000_000
	substitute := client(cur, cs, cons)
	recovery := govern(cur, ibcgov.NewRecoverClientRequest(cross(cur), stalled, substitute))
	execute(cur, recovery)
	println("recovery:", decided(recovery), "| now", core.ClientStatus(stalled), core.VerifierVersion(stalled), core.ClientLatestHeight(stalled))
}

// Output:
// stalled: Expired ethereum/v0 | frozen: Frozen ethereum/testing-freezing
// replace the expired client's verifier: applied - core migrate client: route ethereum-1's meters emptied
// after: Expired ethereum/testing-next 0/72
// replace the frozen client's verifier: spent - spent: client ethereum-2 is Frozen, not Active or Expired | still ethereum/testing-freezing
// recovery: applied - core recover client | now Active ethereum/testing-next 0/5000000
