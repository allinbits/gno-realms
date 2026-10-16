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

var (
	collector = testutils.TestAddress("collector")
	sender    = testutils.TestAddress("sender")
	bob       = testutils.TestAddress("bob")
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
	execute(cur, govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1")))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector))))
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
	testing.SetRealm(testing.NewUserRealm(bob))
	packet, seq := transfer.Transfer(cross(cur), client, ethReceiver, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return packet, seq
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

// The switch to the controls covers every Ethereum client impl/v0 used and
// every denom of their vouchers (Codex round 4 #3, #4): the staged
// activation enables one route and one denom; the other 17 denoms of that
// route, and the vouchers of a second client no decision enrolled, go back
// through the legacy path, recorded, their refunds metered at the
// activation's legacy refund cap. The activated route takes no credit until the return impl/v0
// left outstanding is backfilled; the backfilled return's refund is metered.
func main(cur realm) {
	a := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), a, [][]byte{{}}, "client-0")
	b := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), b, [][]byte{{}}, "client-0")
	const n = 18
	var vouchers []string
	for i := 1; i <= n; i++ {
		recv(cur, a, uint64(i), token(i), bob.String(), 100)
		vouchers = append(vouchers, ics20.NewDenom(token(i), ics20.NewHop("transfer", a)).IBCDenom())
	}
	recv(cur, b, 1, weth, bob.String(), 100)
	onB := ics20.NewDenom(weth, ics20.NewHop("transfer", b)).IBCDenom()
	msg, legacySeq := returnVoucher(cur, a, vouchers[0], 40) // under impl/v0, outstanding across the switch
	legacy := types.NewPacket(legacySeq, a, "client-0", msg.TimeoutTimestamp, msg.Payloads[0])

	execute(cur, govern(cur, ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1",
		a, string(collector), token(1)+" mint 4000 10000 10 1 0 0 4000 -", 4000)))
	println("impl:", transfer.ImplVersion(), "| denoms enabled on", a, ":", len(controlsView().Denoms(a)))

	// Every voucher goes back at once, the 17 denoms no decision enabled and
	// the second client's included, recorded.
	recorded := 0
	var seqs []uint64
	for i := 1; i < n; i++ {
		_, seq := returnVoucher(cur, a, vouchers[i], 10)
		seqs = append(seqs, seq)
		if _, ok := controlsView().Send(a, controls.PacketKey(a, seq)); ok {
			recorded++
		}
	}
	_, seqB := returnVoucher(cur, b, onB, 10)
	_, okB := controlsView().Send(b, controls.PacketKey(b, seqB))
	println("legacy returns recorded:", recorded, "of", n-1, "| on", b, ":", okB, "| legacy route:", controlsView().Legacy(b))

	// No credit before the outstanding legacy return is imported.
	println("credit before the backfill:", recv(cur, a, 100, token(1), sender.String(), 50).Status)
	backfill(cur, legacy)
	println("credit after it:", recv(cur, a, 101, token(1), sender.String(), 50).Status)

	// The backfilled return times out: its refund goes through the refund
	// meter of the enabled denom; a legacy denom's waits until enabled.
	if err := timeoutAsCore(cur, a, legacySeq, legacy.Payloads[0]); err != nil {
		panic(err)
	}
	rec, _ := controlsView().Send(a, controls.PacketKey(a, seqs[0]))
	if err := timeoutAsCore(cur, a, seqs[0], rec.Packet.Payloads[0]); err != nil {
		panic(err)
	}
	advance(24 * time.Hour)
	transfer.ClaimRefunds(cross(cur), a, vouchers[0], 20)
	transfer.ClaimRefunds(cross(cur), a, vouchers[1], 20)
	println("enabled denom's refund:", refundState(a, legacySeq), "| legacy denom's:", refundState(a, seqs[0]))
	// The legacy denom's refund is paid by its meter, at the activation's
	// legacy refund cap, with no further decision (Codex round 5 #6).
}

// Output:
// impl: v1 | denoms enabled on ethereum-1 : 1
// legacy returns recorded: 17 of 17 | on ethereum-2 : true | legacy route: true
// credit before the backfill: (2 gno.land/p/aib/ibc/types/v0.PacketStatus)
// credit after it: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// enabled denom's refund: outcome timeout, payment claimed, refunded 40, backfilled true | legacy denom's: outcome timeout, payment claimed, refunded 10, backfilled false
