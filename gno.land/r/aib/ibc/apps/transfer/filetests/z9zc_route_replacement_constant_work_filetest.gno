// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
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

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	sender    = testutils.TestAddress("sender")
	bob       = testutils.TestAddress("bob")
	guardian  = testutils.TestAddress("guardian-0")
)

const (
	ethReceiver = "0x5f67a5398d91087d1b37a8a43436196a7830867f"
	weth        = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"
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

// setupRoute creates an Ethereum client, installs transfer impl/v1 and
// enrolls the client as a route, every step a governor decision.
func setupRoute(cur realm) string {
	clientID := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", clientID+" "+string(collector)+" "+bridge)))
	advance(7*24*time.Hour + time.Second) // the separate enrollment's delay, kept so the timeline stays
	return clientID
}

// send transfers amount of ugnot from sender to an Ethereum receiver, sending
// coins with the call (the coins land at the transfer realm first).
func send(cur realm, route string, amount, coins int64, receiver string) uint64 {
	testing.IssueCoins(chain.PackageAddress(transfer.PkgPath), chain.NewCoins(chain.NewCoin("ugnot", coins)))
	testing.SetRealm(testing.NewUserRealm(sender))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", coins)))
	_, seq := transfer.Transfer(cross(cur), route, receiver, "ugnot", amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

// recv delivers a packet from Ethereum to the transfer app as the core does
// after verifying its proof.
func recv(cur realm, route string, seq uint64, denom, receiver string, amount int64) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatInt(amount, 10), "0x5f67a5398d91087d1b37a8a43436196a7830867f", receiver, "")
	bz, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), "client-0", route, seq, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return res
}

func controlsView() controls.Reader { return transfer.ExtView("controls").(controls.Reader) }

func ugnot(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, "ugnot") }

func refundState(client string, seq uint64) string {
	r, ok := controlsView().Send(client, controls.PacketKey(client, seq))
	if !ok {
		return "no record"
	}
	return "outcome " + r.Outcome + ", payment " + r.Payment + ", refunded " + strconv.FormatInt(r.Refunded, 10) +
		", backfilled " + strconv.FormatBool(r.Backfilled)
}

// returnVoucher sends amount of bob's vouchers back to Ethereum.
func returnVoucher(cur realm, client, voucher string, amount int64) (types.MsgSendPacket, uint64) {
	return returnVoucherTo(cur, client, voucher, amount, ethReceiver)
}

func returnVoucherTo(cur realm, client, voucher string, amount int64, to string) (types.MsgSendPacket, uint64) {
	testing.SetRealm(testing.NewUserRealm(bob))
	defer testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return transfer.Transfer(cross(cur), client, to, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
}

func backfill(cur realm, p types.Packet) {
	testing.SetRealm(testing.NewUserRealm(sender)) // anyone
	transfer.Backfill(cross(cur), p)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

// token is the Ethereum address of test token i.
func token(i int) string {
	s := strconv.Itoa(i)
	return "0x" + strings.Repeat("a", 40-len(s)) + s
}

func timeoutAsCore(cur realm, client string, seq uint64, p types.Payload) error {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	err := app.OnTimeoutPacket(cross(cur), client, "client-0", seq, p)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return err
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// unrelated is how many voucher denoms another chain's client brings.
const unrelated = 40

// A replacement reads the candidate's transfer state from counters kept as
// balances change, so its work does not grow with the voucher denoms of
// other clients (Codex round 9 #2): many unrelated voucher denoms, then a
// replacement by a fresh client, which holds none.
func main(cur realm) {
	a := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), a, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1",
		a+" "+string(collector)+" "+bridge)))
	for i := 1; i <= unrelated; i++ {
		recv(cur, "07-tendermint-9", uint64(i), token(i), bob.String(), 100)
	}
	c := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), c, [][]byte{{}}, "client-1")
	println("assets of 07-tendermint-9:", transfer.ClientAssetCount("07-tendermint-9"), "| of", c+":", transfer.ClientAssetCount(c))
	replace := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), a, c, 1))
	execute(cur, replace)
	println("replace:", decided(replace))
}

// Output:
// assets of 07-tendermint-9: 40 | of ethereum-2: 0
// replace: applied - replace: client ethereum-1 retired, meters emptied
