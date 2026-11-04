// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
	"strings"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// routerID is a custom Ethereum router client id of n characters.
func routerID(n int) string { return "gnoland." + strings.Repeat("x", n-len("gnoland.")) }

func payload() types.Payload {
	return types.Payload{SourcePort: "appID", DestinationPort: "appID", Encoding: "application/json", Value: []byte("{}"), Version: "v1"}
}

// An Ethereum router's custom client ids run to 128 characters, beyond the
// 64 of an ICS24 identifier (Codex round 3 #4): an Ethereum client pairs with
// one of 64, 65 or 128 characters and carries packets both ways; 129 is
// refused at registration. Local client ids keep the SDK's limits.
func main(cur realm) {
	app := appstesting.NewApp(cross(cur))
	app.SetOnRecvPacketReturn(types.RecvPacketResult{Status: types.PacketStatus_Success, Acknowledgement: []byte("ok")})
	core.RegisterApp(cross(cur), "appID", app)
	for i, n := range []int{64, 65, 128} {
		local := "ethereum-" + strconv.Itoa(i+1)
		remote := routerID(n)
		in := types.Packet{Sequence: 1, SourceClient: remote, DestinationClient: local,
			TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()), Payloads: []types.Payload{payload()}}
		router := ethtesting.NewRouter()
		router.CommitPacket(in)
		id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
		core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, remote)
		core.RecvPacket(cross(cur), types.MsgRecvPacket{Packet: in, ProofHeight: types.NewHeight(0, 72), Ext: extproof.Proof{Data: router.Proof()}})
		seq := core.SendPacket(cross(cur), types.MsgSendPacket{SourceClient: id,
			TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()), Payloads: []types.Payload{payload()}})
		println(n, "characters:", id == local, "| received:", len(core.PacketReceipt(id, 1)) > 0, "| sent:", seq, len(core.PacketCommitment(id, seq)) > 0)
	}
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	println("129 characters:", revive(func() { core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, routerID(129)) }))
}

// Output:
// 64 characters: true | received: true | sent: 1 true
// 65 characters: true | received: true | sent: 1 true
// 128 characters: true | received: true | sent: 1 true
// 129 characters: invalid counterparty client id
