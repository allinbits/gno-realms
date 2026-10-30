// PKGPATH: gno.land/r/demo/attacker
package attacker

import (
	"time"

	"gno.land/p/aib/ibc/host/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// prefix is this realm's own, persistent: what it hands the core.
var prefix = [][]byte{{}}

// An Ethereum client's counterparty prefix is eureka's canonical single empty
// element, and the core keeps its own copy (Codex round 6 #1): the creator's
// later change to the slice it registered moves nothing, so proofs keep
// authenticating the router's keys.
func main(cur realm) {
	println("a non-canonical prefix:", revive(func() {
		id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
		core.RegisterCounterparty(cross(cur), id, [][]byte{[]byte("x")}, "client-0")
	}))

	p := types.Packet{Sequence: 1, SourceClient: "client-0", DestinationClient: "ethereum-2",
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads:         []types.Payload{{SourcePort: "appID", DestinationPort: "appID", Encoding: "application/json", Value: []byte("{}"), Version: "v1"}}}
	router := ethtesting.NewRouter()
	router.CommitPacket(p)
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	core.RegisterCounterparty(cross(cur), id, prefix, "client-0")
	println("mutating the registered slice:", revive(func() { prefix[0] = []byte("x") }), "| ours now:", string(prefix[0]))

	v, err := core.CounterpartyValue(id, types.NewHeight(0, 72), router.Proof(), host.PacketCommitmentKey("client-0", 1))
	println("the router's commitment still proves:", err == nil && string(v) == string(types.CommitPacket(p)))
}

// Output:
// a non-canonical prefix: an Ethereum counterparty's merkle prefix is a single empty element
// mutating the registered slice: undefined | ours now: x
// the router's commitment still proves: true
