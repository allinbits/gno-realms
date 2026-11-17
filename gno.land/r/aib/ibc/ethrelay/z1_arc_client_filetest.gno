// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
	"strings"
	"testing"
	"time"

	arctesting "gno.land/p/aib/ibc/lightclient/arc/testing/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ethrelay"
)

// An Arc client through the relay realm, on Arc testnet data: created from a
// block's header and registry proofs, given its router counterparty,
// updated by a relayer the whitelist does not list (relaying for a router
// client is permissionless), and rendered for relayers.
func main(cur realm) {
	testing.SetContext(testing.Context{Time: time.Unix(arctesting.Time, 0)})
	id := ethrelay.CreateArcClient(cross(cur), arctesting.Creation)
	println("created:", id, core.ClientType(id), core.ClientStatus(id))
	println("router client:", core.IsRouterClient(id))
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")

	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.AddRelayer(cross(cur), "g1relayer000000000000000000000000000000")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	ethrelay.UpdateArcClient(cross(cur), id, arctesting.Header)
	println("latest is the update's block:", core.ClientLatestHeight(id) == "0/"+strconv.FormatUint(arctesting.UpdateHeight, 10), core.ClientLatestHeight(id) != "0/"+strconv.FormatUint(arctesting.CreationHeight, 10))

	js := core.Render("clients/" + id)
	println("render has the registry root:", strings.Contains(js, `"registry_storage_root"`))
	println("render has the validators:", strings.Contains(js, `"next_validators"`))

	println("garbage:", revive(func() { ethrelay.UpdateArcClient(cross(cur), id, []byte{1, 2, 3}) }) != nil)
}

// Output:
// created: arc-1 arc Active
// router client: true
// latest is the update's block: true true
// render has the registry root: true
// render has the validators: true
// garbage: true
