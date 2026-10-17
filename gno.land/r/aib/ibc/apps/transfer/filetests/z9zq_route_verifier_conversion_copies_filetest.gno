// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/v0"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	implv1 "gno.land/r/aib/ibc/core/impl/v1"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	sender    = testutils.TestAddress("sender")
	bob       = testutils.TestAddress("bob")
	carol     = testutils.TestAddress("carol")
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
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector), bridge)))
	advance(7*24*time.Hour + time.Second) // keeps the timeline of the goldens
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

// recvOn delivers a packet arriving on client dst from the router client src.
func recvOn(cur realm, src, dst string, seq uint64, denom, receiver string, amount int64) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatInt(amount, 10), ethReceiver, receiver, "")
	bz, _ := abi.Marshal(data)
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), src, dst, seq, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return res
}

func sendVoucher(cur realm, client, voucher string, amount int64) uint64 {
	testing.SetRealm(testing.NewUserRealm(bob))
	_, seq := transfer.Transfer(cross(cur), client, ethReceiver, voucher, amount, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return seq
}

func wireDenom(route, client string, seq uint64) string {
	rec, _ := controlsView().Send(route, controls.PacketKey(client, seq))
	data, _ := abi.Unmarshal(rec.Packet.Payloads[0].Value)
	return data.Denom
}

// meters reads the route's bridge meter and bob's meter of denom now.
func meters(route, denom string) string {
	epoch, at := ibcgov.PayoutsEpoch(route)
	b, r := controlsView().Meters(route, denom, bob, time.Now().Unix(), epoch, at, 0)
	return "bridge " + strconv.FormatInt(b, 10) + ", bob " + strconv.FormatInt(r, 10)
}

// sendBack is the home page's "send back" action of the voucher (its link
// names the client the return goes through).
func sendBack() string {
	for _, line := range strings.Split(transfer.Render(""), "\n") {
		if i := strings.Index(line, "send back"); i >= 0 {
			j := strings.Index(line[i:], " — ")
			return line[i : i+j]
		}
	}
	return "none"
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

func claimState(route string, seq uint64) string {
	c, _ := controlsView().Claim(route, controls.PacketKey(route, seq))
	return c.State + " paid " + strconv.FormatInt(c.Paid, 10)
}

func setTime(t time.Time) {
	ctx := testing.GetContext()
	ctx.Time = t
	testing.SetContext(ctx)
}

const chainImpl = "gno.land/r/aib/ibc/core/impl/v1chain"

// Successive conversions never write a live trusted root (Codex round 28
// #1): after a client's verifier became NextVerifier, a second conversion
// that rewrites the root NewFrom serves for the latest height, then refuses
// or panics, rewrote only a copy. The receipt is still proven against the
// original root, and the trust generation and payouts epoch are unchanged.
func main(cur realm) {
	router := ethtesting.NewRouter()
	packet := types.Packet{Sequence: 1, SourceClient: "ethereum-1", DestinationClient: "client-0", TimeoutTimestamp: 1,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/x-solidity-abi", Value: []byte{1}}}}
	router.CommitReceipt(packet)
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(collector), bridge)))
	testing.SetRealm(testing.NewCodeRealm(chainImpl))
	core.RegisterImpl(cross(cur), func(s core.Store) core.Logic {
		return implv1.NewWithConversions(s, "v1-chain",
			[]string{ethereum.Version, ethtesting.NextVersion, ethtesting.NextVersion},
			[]string{ethtesting.NextVersion, ethtesting.RewriteVersion, ethtesting.RewritePanicVersion},
			[]func(*ethereum.Retired) lightclient.Interface{ethtesting.ToNextVerifier, ethtesting.ToRootRewriter, ethtesting.ToRootRewriterPanicking})
	}, "v1-chain", []string{"v0", "v1"})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), chainImpl)))

	key := host.PacketReceiptKey(packet.DestinationClient, packet.Sequence)
	proves := func() bool {
		v, err := core.CounterpartyValue(client, types.NewHeight(0, 72), router.Proof(), key)
		return err == nil && string(v) == string(ethereum.PacketReceiptCommitment(packet))
	}
	first := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), client, ethtesting.NextVersion))
	execute(cur, first)
	println("first conversion:", decided(first), "| verifier", core.VerifierVersion(client), "| proves the receipt:", proves())

	for _, to := range []string{ethtesting.RewriteVersion, ethtesting.RewritePanicVersion} {
		gen := core.ClientTrustGeneration(client)
		epoch, _ := ibcgov.PayoutsEpoch(client)
		before := core.Render("clients/" + client)
		replace := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), client, to))
		execute(cur, replace)
		epoch2, _ := ibcgov.PayoutsEpoch(client)
		println(to+":", decided(replace))
		println("  proves the receipt:", proves(), "| state unchanged:", core.Render("clients/"+client) == before,
			"| trust generation unchanged:", core.ClientTrustGeneration(client) == gen, "| payouts epoch unchanged:", epoch2 == epoch)
	}
}

// Output:
// first conversion: applied - core migrate client: route ethereum-1's meters emptied | verifier ethereum/testing-next | proves the receipt: true
// ethereum/testing-rewrite: spent - spent: the conversion returned no verifier
//   proves the receipt: true | state unchanged: true | trust generation unchanged: true | payouts epoch unchanged: true
// ethereum/testing-rewrite-panic: spent - spent: the converted verifier failed its checks: rewrote a root
//   proves the receipt: true | state unchanged: true | trust generation unchanged: true | payouts epoch unchanged: true
