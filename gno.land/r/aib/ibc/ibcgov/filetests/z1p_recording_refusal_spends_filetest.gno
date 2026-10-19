// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/runtime/unsafe"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
	"gno.land/r/gov/dao"
	daoinit "gno.land/r/gov/dao/init/v0"
)

var member address = unsafe.OriginCaller()

// advance moves the block time on by d.
func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

func client(cur realm, counterparty string) string {
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, counterparty)
	return id
}

func governAs(cur realm, gov address, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(gov))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

// An approved proposal whose recording is refused is used up (code review
// r62 #1): a recovery expectation A→B, built while A had room, is approved;
// A's four successor places fill before it executes, so its recording is
// refused: the proposal executes into a spent decision, with no intent.
// Once a place frees, the same proposal cannot execute again.
func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), member)
	gov := ibcgov.Governor()
	route := client(cur, "client-0")
	b := client(cur, "gnoland-b")
	var locals []string
	for i := 1; i <= 4; i++ {
		locals = append(locals, client(cur, "gnoland-r"+itoa(i)))
	}
	advance(time.Second)
	id := governAs(cur, gov, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(testutils.TestAddress("collector")), bridge))
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
	id = governAs(cur, gov, ibcgov.NewBindGovernanceRequest(cross(cur), route))
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
	reqB := ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-b", b) // room now
	var fill []int64
	for i, l := range locals {
		fill = append(fill, governAs(cur, gov, ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-r"+itoa(i+1), l)))
	}
	testing.SetRealm(testing.NewUserRealm(gov))
	ibcgov.Yield(cross(cur))

	testing.SetOriginCaller(member)
	testing.SetRealm(testing.NewUserRealm(member))
	pid := dao.MustCreateProposal(cross(cur), reqB.Proposal())
	testing.SetRealm(testing.NewUserRealm(member))
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))
	testing.SetRealm(testing.NewUserRealm(member))
	println("A→B executed with A full:", dao.ExecuteProposal(cross(cur), pid))
	d, _ := ibcgov.Decision(ibcgov.LastDecision())
	println("its decision:", d.Kind, "-", d.State(), "-", d.Note)

	// A place frees: the cancellation of one pending expectation.
	testing.SetRealm(testing.NewUserRealm(member))
	cid := dao.MustCreateProposal(cross(cur), ibcgov.NewCancelRequest(cross(cur), fill[0]).Proposal())
	testing.SetRealm(testing.NewUserRealm(member))
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, cid))
	testing.SetRealm(testing.NewUserRealm(member))
	dao.ExecuteProposal(cross(cur), cid)
	testing.SetRealm(testing.NewUserRealm(member))
	println("the same proposal again:", revive(func() { dao.ExecuteProposal(cross(cur), pid) }) != nil)
	println("decisions recorded:", ibcgov.LastDecision())
}

func itoa(i int) string {
	return string(rune('0' + i))
}

// Output:
// A→B executed with A full: true
// its decision: expect recovery - spent - spent: router client client-0 has 4 expected successors already, intents included
// the same proposal again: true
// decisions recorded: 8
