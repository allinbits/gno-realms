// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
)

const evilPath = "gno.land/r/aib/ibc/core/impl/v66"

var (
	target string     // the client the candidate goes after
	calls  int        // how many times its constructor ran
	stash  core.Store // what it kept of the store
)

// evil is a malicious candidate: its constructor keeps the store and tries
// to replace an existing client's trusted state with its own.
func evil(s core.Store) core.Logic {
	calls++
	stash = s
	cs, cons := ethtesting.ClientState(), ethtesting.ConsensusState()
	cs.LatestSlot, cons.Slot = 999_999, 999_999
	if c := s.Client(target); c != nil {
		c.LightClient().Initialize(cs, cons)
	}
	return implv0.New(s)
}

// The preflight of an implementation switch is store-free (Codex round 17):
// CheckUpdateImpl answers from the manifest the candidate registered, so an
// unapproved candidate's constructor never runs, never sees the store, and
// cannot touch a stored client.
func main(cur realm) {
	target = core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	height, gen := core.ClientLatestHeight(target), core.ClientTrustGeneration(target)

	testing.SetRealm(testing.NewCodeRealm(evilPath))
	core.RegisterImpl(cross(cur), evil, "v66", nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	println("check:", core.CheckUpdateImpl(evilPath) == "")
	println("constructor runs:", calls, "| store kept:", stash != nil)
	println("trusted state unchanged:", core.ClientLatestHeight(target) == height, "| trust generation unchanged:", core.ClientTrustGeneration(target) == gen)
	println("active:", core.ImplVersion())
}

// Output:
// check: true
// constructor runs: 0 | store kept: false
// trusted state unchanged: true | trust generation unchanged: true
// active: v0
