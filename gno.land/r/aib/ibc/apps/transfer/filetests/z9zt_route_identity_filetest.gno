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

// client creates an Ethereum client of the given state, its counterparty
// the router client "client-0".
func client(cur realm, cs ethereum.ClientState) string {
	id := core.CreateClient(cross(cur), cs, ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	return id
}

const opaqueImpl = "gno.land/r/aib/ibc/core/impl/v1opaque"

// A route records the history its client authenticates when it is enrolled
// (ADR pr6375 §7.12, "Route identity is preserved"): the Ethereum chain id
// and genesis validators root, the ICS26 router and its commitments slot. The
// bridge's router must be the router the client reads, and every replacement
// must authenticate the same identity: a genuine client of another router
// would prove that router's receipts (an absence after a timeout there makes
// a packet the route's router delivered look refundable), so it is refused
// when the replacement is requested, and a client that no longer names the
// identity when it executes leaves the decision spent.
func main(cur realm) {
	route := client(cur, ethtesting.ClientState())
	println("bridge of another router:", revive(func() {
		govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector),
			"0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"))
	}))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), route, string(collector), bridge)))
	// Replacements need the governance channel bound, over the route's
	// original client.
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), route)))
	println("identity:", ibcgov.RouteIdentity(route))

	// Genuine clients of another router, another commitments slot, another
	// chain: none replaces the route's client.
	cs := ethtesting.ClientState()
	cs.IBCContractAddress = []byte{0xb0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01}
	otherRouter := client(cur, cs)
	cs = ethtesting.ClientState()
	cs.IBCCommitmentSlot = make([]byte, 32)
	otherSlot := client(cur, cs)
	cs = ethtesting.ClientState()
	cs.ChainID = 1
	otherChain := client(cur, cs)
	for _, c := range []string{otherRouter, otherSlot, otherChain} {
		println("replace by", c+":", revive(func() {
			govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, c, 0))
		}))
	}

	// A client of the route's identity is accepted; if it no longer names the
	// identity when the decision executes (here its verifier was replaced by
	// one exposing no Ethereum state), the decision is spent.
	testing.SetRealm(testing.NewCodeRealm(opaqueImpl))
	core.RegisterImpl(cross(cur), func(s core.Store) core.Logic {
		return implv1.NewWithConversions(s, "v1-opaque",
			[]string{ethereum.Version}, []string{ethtesting.OpaqueVersion},
			[]func(*ethereum.Retired) lightclient.Interface{ethtesting.ToOpaqueVerifier})
	}, "v1-opaque", []string{"v0", "v1"})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), opaqueImpl)))
	twin := client(cur, ethtesting.ClientState())
	replace := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, twin, 0))
	execute(cur, govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), twin, ethtesting.OpaqueVersion)))
	ibcgov.Execute(cross(cur), replace)
	println("replacement after its client lost the identity:", decided(replace))
	println("old client retired:", core.IsClientRetired(route))

	// A genuine twin replaces it.
	twin2 := client(cur, ethtesting.ClientState())
	replace = govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), route, twin2, 0))
	execute(cur, replace)
	println("replacement by a client of the identity:", decided(replace), "| old retired:", core.IsClientRetired(route))
	println("identity kept:", ibcgov.RouteIdentity(twin2) == ibcgov.RouteIdentity(route))
}

// Output:
// bridge of another router: ibcgov: the bridge's router 0x00000000000000000000000000000000000b0001 is not the router 0x1d95d544586eacb63b6154e9e45122b32ded11aa that ethereum-1 reads
// identity: chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600
// replace by ethereum-2: ibcgov: ethereum-2 authenticates (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0xb000000000000000000000000000000000000001, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600), not route ethereum-1's (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600)
// replace by ethereum-3: ibcgov: ethereum-3 authenticates (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x0000000000000000000000000000000000000000000000000000000000000000), not route ethereum-1's (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600)
// replace by ethereum-4: ibcgov: ethereum-4 authenticates (chain 1, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600), not route ethereum-1's (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600)
// replacement after its client lost the identity: spent - spent: ethereum-5 authenticates no route identity, not route ethereum-1's (chain 3151908, genesis validators root 0xd1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3, router 0x1d95d544586eacb63b6154e9e45122b32ded11aa, commitment slot 0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600)
// old client retired: false
// replacement by a client of the identity: applied - replace: client ethereum-1 retired for transfers, meters emptied; governance epoch 1 stays over ethereum-1 until IBCAdmin's epoch notices arrive | old retired: false
// identity kept: true
