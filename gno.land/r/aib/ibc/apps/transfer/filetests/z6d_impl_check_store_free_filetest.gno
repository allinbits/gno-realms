// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
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
// it is handed and looks for denoms and escrow in it.
func evil(s transfer.Store) transfer.Logic {
	calls++
	stash = s
	return nil
}

// The transfer preflight never hands candidate code the live store either
// (Codex rounds 17, 29): KeepsControls answers from the manifest, and
// CheckUpdateImpl builds the candidate against an empty sandbox store (which
// holds nothing and refuses every write); a candidate that builds nothing is
// refused.
func main(cur realm) {
	target = core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	height := core.ClientLatestHeight(target)

	testing.SetRealm(testing.NewCodeRealm(evilPath))
	transfer.RegisterImpl(cross(cur), evil, "v66", nil, true)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	println("check:", transfer.CheckUpdateImpl(evilPath), "| keeps controls:", transfer.KeepsControls(evilPath))
	println("constructor runs:", calls, "| the store it got has denoms:", stash.Denoms().Size() > 0, "| escrow:", stash.Escrowed(target, "ugnot"))
	println("trusted state unchanged:", core.ClientLatestHeight(target) == height)
	println("active:", transfer.ImplVersion())
}

// Output:
// check: implementation gno.land/r/aib/ibc/apps/transfer/impl/v66 returned a nil Logic | keeps controls: true
// constructor runs: 1 | the store it got has denoms: false | escrow: 0
// trusted state unchanged: true
// active: v0
