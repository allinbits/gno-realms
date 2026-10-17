// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

const evilPath = "gno.land/r/aib/ibc/apps/transfer/impl/v66"

var (
	target string         // a core client, which stays untouched
	calls  int            // how many times its constructor ran
	stash  transfer.Store // what it kept of the store
)

// evil is a malicious transfer candidate: its constructor keeps the store
// and tries to write the denoms it holds.
func evil(s transfer.Store) transfer.Logic {
	calls++
	stash = s
	s.Denoms().Set("evil", nil)
	return nil
}

// The transfer preflight is store-free too (Codex round 17): CheckUpdateImpl
// and KeepsControls answer from the registered manifest, so an unapproved
// candidate's constructor never runs and never sees the store.
func main(cur realm) {
	target = core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	height := core.ClientLatestHeight(target)

	testing.SetRealm(testing.NewCodeRealm(evilPath))
	transfer.RegisterImpl(cross(cur), evil, "v66", nil, true)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	println("check:", transfer.CheckUpdateImpl(evilPath) == "", "| keeps controls:", transfer.KeepsControls(evilPath))
	println("constructor runs:", calls, "| store kept:", stash != nil)
	println("trusted state unchanged:", core.ClientLatestHeight(target) == height)
	println("active:", transfer.ImplVersion())
}

// Output:
// check: true | keeps controls: true
// constructor runs: 0 | store kept: false
// trusted state unchanged: true
// active: v1
