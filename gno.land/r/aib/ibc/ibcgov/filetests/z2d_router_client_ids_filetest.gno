// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// advance moves the block time on by d.
func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

// govern makes a decision as the governor and returns its number.
func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

// execute applies a queued decision once its 7 days have passed.
func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

var (
	collector = testutils.TestAddress("collector")
	bob       = testutils.TestAddress("bob")
)

const weth = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"

// Ethereum router client ids follow eureka's grammar, not the SDK's {type}-{N}
// (Codex review #12): a router generates "client-N", and governance adds
// custom ids, such as the suffixless "gnoland", of 4 to 128 characters not
// starting with "client-" or "channel-". The core pairs an Ethereum client
// with such a counterparty, the transfer app carries packets from it, and the
// Ethereum-bound builders take the router's ids and refuse the ids eureka
// refuses.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "gnoland")
	println("counterparty:", core.CounterpartyClientID(client))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), client)))

	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), "gnoland", 86400))
	govern(cur, ibcgov.NewEthClientRequest(cross(cur), 1, "gnoland.v2", client, "6d61696e", "0x1111111111111111111111111111111111111111", "abababababababababababababababababababababababababababababababab"))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "gnoland", "gnoland.v2"))
	println("dispatched:", ibcgov.LastSeq(1))
	for _, id := range []string{"channel-1", "client-7", "abc", "gno/land"} {
		println("add", id+":", revive(func() {
			govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "gnoland", id))
		}))
	}
	println("settings client-01:", revive(func() { govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), "client-01", 1)) }))

	// The transfer app carries a packet from the router client "gnoland".
	execute(cur, govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1")))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(collector))))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), client, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000)))
	data := ics20.NewFungibleTokenPacketData(weth, "100", "0x5f67a5398d91087d1b37a8a43436196a7830867f", bob.String(), "")
	bz, _ := abi.Marshal(data)
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), "gnoland", client, 1, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	println("receive from gnoland:", res.Status == types.PacketStatus_Success)
}

// Output:
// counterparty: gnoland
// dispatched: 3
// add channel-1: ibcgov: a router client id added by governance is a custom id: 4 to 128 characters of a-z A-Z 0-9 . _ + - # [ ] < >, not starting with client- or channel-: channel-1
// add client-7: ibcgov: a router client id added by governance is a custom id: 4 to 128 characters of a-z A-Z 0-9 . _ + - # [ ] < >, not starting with client- or channel-: client-7
// add abc: ibcgov: a router client id added by governance is a custom id: 4 to 128 characters of a-z A-Z 0-9 . _ + - # [ ] < >, not starting with client- or channel-: abc
// add gno/land: ibcgov: a router client id added by governance is a custom id: 4 to 128 characters of a-z A-Z 0-9 . _ + - # [ ] < >, not starting with client- or channel-: gno/land
// settings client-01: ibcgov: not an Ethereum router client id: client-01
// receive from gnoland: true
