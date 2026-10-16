// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	_ "gno.land/r/aib/ibc/core/impl/v1"
	"gno.land/r/aib/ibc/ibcgov"
)

func setTime(t time.Time) {
	ctx := testing.GetContext()
	ctx.Time = t
	testing.SetContext(ctx)
}

func advance(d time.Duration) {
	ctx := testing.GetContext()
	setTime(ctx.Time.Add(d))
}

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// client creates an Ethereum client at slot with a sync committee period of
// epochs epochs (its trusting window is 8 periods).
func client(cur realm, slot, epochs uint64) string {
	cs := ethtesting.ClientState()
	cs.LatestSlot, cs.LatestExecutionBlockNumber, cs.EpochsPerSyncCommitteePeriod = slot, slot, epochs
	cons := ethtesting.ConsensusState()
	cons.Slot = slot
	id := core.CreateClient(cross(cur), cs, cons)
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	return id
}

// A governed recovery or migration that the light client would refuse is
// refused when its decision executes, and the decision is spent (ADR pr6375
// §5.4, §6.6; Codex round 2 #3): it never aborts and stays pending, to run
// later under its old approval once the clients have moved.
func main(cur realm) {
	// A migration that leaves the fork schedule unchanged: the light client
	// refuses it.
	id := client(cur, 72, 8)
	execute := func(d int64) {
		advance(7*24*time.Hour + time.Second)
		ibcgov.Execute(cross(cur), d)
	}
	execute(govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v1")))
	same := hex.EncodeToString(ethereum.EncodeForkParameters(ethtesting.ClientState().ForkParameters))
	migrate := govern(cur, ibcgov.NewMigrateClientRequest(cross(cur), id, "ethereum-fork-schedule", same))
	execute(migrate)
	println("migration:", decided(migrate))

	// The subject (a one-epoch period: a short window) expires; the
	// substitute is Active but tracks the chain with another period, which
	// the light client refuses.
	subject := client(cur, 72, 1)
	substitute := client(cur, 72, 8)
	rec := govern(cur, ibcgov.NewRecoverClientRequest(cross(cur), subject, substitute))
	genesis := int64(ethtesting.ClientState().GenesisTime)
	setTime(time.Unix(genesis+400, 0)) // slot 200: the subject expired, the substitute Active
	println("subject", core.ClientStatus(subject), "| substitute", core.ClientStatus(substitute))
	ibcgov.Execute(cross(cur), rec)
	println("recovery:", decided(rec))

	// A substitute that has advanced and would now be accepted: the old
	// approval never applies.
	matching := client(cur, 150, 1)
	println("matching substitute:", core.ClientStatus(matching), "| check:", core.CheckRecoverClient(subject, matching) == "")
	println("retry:", revive(func() { ibcgov.Execute(cross(cur), rec) }))
	println("subject still", core.ClientStatus(subject))
}

// Output:
// migration: spent - spent: the fork schedule is unchanged
// subject Expired | substitute Active
// recovery: spent - spent: substitute client tracks a different chain or router
// matching substitute: Active | check: true
// retry: ibcgov: decision 3 is spent, not pending
// subject still Expired
