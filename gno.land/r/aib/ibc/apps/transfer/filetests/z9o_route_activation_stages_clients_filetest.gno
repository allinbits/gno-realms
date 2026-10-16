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

// The staged activation covers every Ethereum client that holds transfer
// state, with every denom it holds assets of, and nothing falls back (Codex
// round 8, decision A): the builder refuses a gap; a client that gains
// vouchers during the delay spends the decision; the re-proposed activation
// enrolls all three clients at once, their bridge contracts protected and
// their vouchers going back from the switch; an Ethereum client without a
// route carries nothing; the outstanding impl/v0 return is backfilled before
// credits start, and a refunds flag on a staged route holds its refunds.
func main(cur realm) {
	a := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), a, [][]byte{{}}, "client-0")
	b := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), b, [][]byte{{}}, "client-0")
	var vouchers []string
	for i := 1; i <= 3; i++ {
		recv(cur, a, uint64(i), token(i), bob.String(), 100)
		vouchers = append(vouchers, ics20.NewDenom(token(i), ics20.NewHop("transfer", a)).IBCDenom())
	}
	recv(cur, b, 1, weth, bob.String(), 100)
	onB := ics20.NewDenom(weth, ics20.NewHop("transfer", b)).IBCDenom()
	msg, legacySeq := returnVoucher(cur, a, vouchers[0], 40) // under impl/v0, outstanding across the switch
	legacy := types.NewPacket(legacySeq, a, "client-0", msg.TimeoutTimestamp, msg.Payloads[0])

	mint := func(base string) string { return base + " mint 4000 10000 10 1 0 0 4000 -" }
	const bBridge = "0x00000000000000000000000000000000000b0021 0x00000000000000000000000000000000000b0022 0x00000000000000000000000000000000000b0023"
	const cBridge = "0x00000000000000000000000000000000000b0031 0x00000000000000000000000000000000000b0032 0x00000000000000000000000000000000000b0033"
	routeA := a + " " + string(collector) + " " + bridge + ": " + mint(token(1)) + "; " + mint(token(2)) + "; " + mint(token(3))
	routeB := b + " " + string(collector) + " " + bBridge + ": " + mint(weth)
	activation := func(routes ...string) ibcgov.Request {
		return ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", strings.Join(routes, " | "))
	}
	println("without b:", revive(func() { activation(routeA) }))
	println("without a denom of a:", revive(func() {
		activation(a+" "+string(collector)+" "+bridge+": "+mint(token(1))+"; "+mint(token(2)), routeB)
	}))

	// A third client gains vouchers under impl/v0 during the delay.
	first := govern(cur, activation(routeA, routeB))
	c := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), c, [][]byte{{}}, "client-0")
	recv(cur, c, 1, weth, bob.String(), 100)
	onC := ics20.NewDenom(weth, ics20.NewHop("transfer", c)).IBCDenom()
	execute(cur, first)
	d, _ := ibcgov.Decision(first)
	println("the first activation:", d.State(), "-", d.Note, "| impl:", transfer.ImplVersion())

	routeC := c + " " + string(collector) + " " + cBridge + ": " + mint(weth)
	execute(cur, govern(cur, activation(routeA, routeB, routeC)))
	println("impl:", transfer.ImplVersion(), "| routes:", len(controlsView().Routes()), "| denoms on", a, ":", len(controlsView().Denoms(a)))

	// From the switch: every staged client's vouchers go back, recorded,
	// never to its own bridge contracts.
	for _, to := range []string{"0x00000000000000000000000000000000000b0021", "0x00000000000000000000000000000000000B0022", "0x00000000000000000000000000000000000b0023"} {
		println("return on", b, "to", to+":", revive(func() { returnVoucherTo(cur, b, onB, 1, to) }))
	}
	println("return on", c, "to its router:", revive(func() { returnVoucherTo(cur, c, onC, 1, "0x00000000000000000000000000000000000b0031") }))
	recorded := 0
	for _, v := range vouchers {
		_, seq := returnVoucher(cur, a, v, 10)
		if _, ok := controlsView().Send(a, controls.PacketKey(a, seq)); ok {
			recorded++
		}
	}
	_, seqB := returnVoucher(cur, b, onB, 10)
	_, seqC := returnVoucher(cur, c, onC, 10)
	_, okB := controlsView().Send(b, controls.PacketKey(b, seqB))
	_, okC := controlsView().Send(c, controls.PacketKey(c, seqC))
	println("returns recorded on", a, ":", recorded, "| on", b, ":", okB, "| on", c, ":", okC)

	// An Ethereum client without a route carries nothing.
	e := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), e, [][]byte{{}}, "client-0")
	println("receive over", e, ":", recv(cur, e, 1, weth, bob.String(), 100).Status == types.PacketStatus_Failure)

	// No credit before the outstanding impl/v0 return is imported.
	println("credit before the backfill:", recv(cur, a, 100, token(1), sender.String(), 50).Status)
	backfill(cur, legacy)
	println("credit after it:", recv(cur, a, 101, token(1), sender.String(), 50).Status)
	if err := timeoutAsCore(cur, a, legacySeq, legacy.Payloads[0]); err != nil {
		panic(err)
	}
	advance(24 * time.Hour)
	transfer.ClaimRefunds(cross(cur), a, vouchers[0], 20)
	println("the backfilled return's refund:", refundState(a, legacySeq))

	// A guardian holds the refunds of the staged route b.
	execute(cur, govern(cur, ibcgov.NewSetSeatsRequest(cross(cur), "0:"+string(guardian))))
	testing.SetRealm(testing.NewUserRealm(guardian))
	ibcgov.SetFlag(cross(cur), b, ibcgov.FnRefunds, "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	_, seqB2 := returnVoucher(cur, b, onB, 10)
	for _, seq := range []uint64{seqB, seqB2} {
		rec, _ := controlsView().Send(b, controls.PacketKey(b, seq))
		if err := timeoutAsCore(cur, b, seq, rec.Packet.Payloads[0]); err != nil {
			panic(err)
		}
	}
	advance(24 * time.Hour)
	transfer.ClaimRefunds(cross(cur), b, onB, 20)
	println("held:", refundState(b, seqB), "|", refundState(b, seqB2))
	testing.SetRealm(testing.NewUserRealm(guardian))
	ibcgov.ClearFlag(cross(cur), b, ibcgov.FnRefunds)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	transfer.ClaimRefunds(cross(cur), b, onB, 20)
	println("cleared:", refundState(b, seqB), "|", refundState(b, seqB2))
}

// Output:
// without b: ibcgov: Ethereum client ethereum-2 holds transfer state and is not staged
// without a denom of a: ibcgov: client ethereum-1 holds assets of a denom that is not staged
// the first activation: spent - spent: Ethereum client ethereum-3 holds transfer state and is not staged | impl: v0
// impl: v1 | routes: 3 | denoms on ethereum-1 : 3
// return on ethereum-2 to 0x00000000000000000000000000000000000b0021: the receiver is a contract of the bridge
// return on ethereum-2 to 0x00000000000000000000000000000000000B0022: the receiver is a contract of the bridge
// return on ethereum-2 to 0x00000000000000000000000000000000000b0023: the receiver is a contract of the bridge
// return on ethereum-3 to its router: the receiver is a contract of the bridge
// returns recorded on ethereum-1 : 3 | on ethereum-2 : true | on ethereum-3 : true
// receive over ethereum-4 : true
// credit before the backfill: (2 gno.land/p/aib/ibc/types/v0.PacketStatus)
// credit after it: (1 gno.land/p/aib/ibc/types/v0.PacketStatus)
// the backfilled return's refund: outcome timeout, payment claimed, refunded 40, backfilled true
// held: outcome timeout, payment queued, refunded 0, backfilled false | outcome timeout, payment queued, refunded 0, backfilled false
// cleared: outcome timeout, payment claimed, refunded 10, backfilled false | outcome timeout, payment claimed, refunded 10, backfilled false
