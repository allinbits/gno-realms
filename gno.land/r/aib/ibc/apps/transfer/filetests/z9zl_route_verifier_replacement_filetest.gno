// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"chain/banker"
	"encoding/hex"
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
func send(cur realm, route string, amount uint256, coins int64, receiver string) uint64 {
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
func recv(cur realm, route string, seq uint64, denom, receiver string, amount uint256) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatUint256(amount, 10), "0x5f67a5398d91087d1b37a8a43436196a7830867f", receiver, "")
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
func recvOn(cur realm, src, dst string, seq uint64, denom, receiver string, amount uint256) types.RecvPacketResult {
	data := ics20.NewFungibleTokenPacketData(denom, strconv.FormatUint256(amount, 10), ethReceiver, receiver, "")
	bz, _ := abi.Marshal(data)
	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app transfer.App
	res := app.OnRecvPacket(cross(cur), src, dst, seq, payload)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return res
}

func sendVoucher(cur realm, client, voucher string, amount uint256) uint64 {
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
	return "bridge " + strconv.FormatUint256(b, 10) + ", bob " + strconv.FormatUint256(r, 10)
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
	return c.State + " paid " + strconv.FormatUint256(c.Paid, 10)
}

func setTime(t time.Time) {
	ctx := testing.GetContext()
	ctx.Time = t
	testing.SetContext(ctx)
}

const nextImpl = "gno.land/r/aib/ibc/core/impl/v1next"

// installNext registers and installs, by a governed upgrade, a core
// implementation that compiles in the conversion of ethereum/v0 verifiers to
// NextVerifier.
func installNext(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(nextImpl))
	core.RegisterImpl(cross(cur), func(s core.Store) core.Logic {
		return implv1.NewWithConversions(s, "v1-next", []string{ethereum.Version}, []string{ethtesting.NextVersion},
			[]func(*ethereum.Retired) lightclient.Interface{ethtesting.ToNextVerifier})
	}, "v1-next", []string{"v0", "v1"})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), nextImpl)))
}

// A governed verifier replacement (ADR pr6375 R16, Codex round 26 #2, #3):
// the conversion is code of the active core implementation, which declares
// it as plain values; a live Ethereum client's verifier becomes NextVerifier,
// which serves every consensus state the retired verifier trusted (read
// only) and stores its own apart. Its id, consensus states and proofs stay,
// its trust generation advances, its route's payout meters start empty.
func main(cur realm) {
	router := ethtesting.NewRouter()
	packet := types.Packet{Sequence: 1, SourceClient: "ethereum-1", DestinationClient: "client-0", TimeoutTimestamp: 1,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/x-solidity-abi", Value: []byte{1}}}}
	router.CommitReceipt(packet)
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/v1")))

	key := host.PacketReceiptKey(packet.DestinationClient, packet.Sequence)
	proves := func() bool {
		v, err := core.CounterpartyValue(client, types.NewHeight(0, 72), router.Proof(), key)
		return err == nil && string(v) == string(ethereum.PacketReceiptCommitment(packet))
	}
	gen := core.ClientTrustGeneration(client)
	epoch, _ := ibcgov.PayoutsEpoch(client)
	println("before: verifier", core.VerifierVersion(client), "| proves the receipt:", proves())
	// impl/v1 compiles no conversion in: the replacement is spent.
	none := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), client, ethtesting.NextVersion))
	execute(cur, none)
	println("under impl/v1:", decided(none), "| verifier", core.VerifierVersion(client))

	installNext(cur)
	replace := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), client, ethtesting.NextVersion))
	execute(cur, replace)
	epoch2, _ := ibcgov.PayoutsEpoch(client)
	println("under", core.ImplVersion()+":", decided(replace))
	println("after: verifier", core.VerifierVersion(client), "| same client:", core.ClientType(client), "| status", core.ClientStatus(client),
		"| trust generation advanced:", core.ClientTrustGeneration(client) > gen, "| payouts epoch", epoch, "->", epoch2)
	// Slot 72 is the retired verifier's: proven through the new one.
	println("proves the receipt at the pre-replacement height:", proves(), "| renders its state:", strings.Contains(core.Render("clients/"+client), "\"latest_execution_block_number\""))
	again := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), client, ethtesting.NextVersion))
	execute(cur, again)
	println("again:", decided(again))

	// The converted verifier keeps the fork-schedule migration: it embeds
	// the v0 verifier's (Codex docs round 4 #2).
	fp := ethtesting.ClientState().ForkParameters
	fp.Gloas = ethereum.Fork{Version: [4]byte{0x80, 0, 0, 0x38}, Epoch: 20}
	forks := govern(cur, ibcgov.NewMigrateClientRequest(cross(cur), client, "ethereum-fork-schedule", hex.EncodeToString(ethereum.EncodeForkParameters(fp))))
	execute(cur, forks)
	println("fork schedule on the converted verifier:", decided(forks), "| still", core.VerifierVersion(client), "| proves the receipt:", proves())

	// A client that expires during the delay is converted all the same,
	// staying Expired (design review #6; a recovery follows, z9zu).
	other := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	late := govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), other, ethtesting.NextVersion))
	setTime(time.Unix(int64(ethtesting.ClientState().GenesisTime)+5000, 0))
	execute(cur, late)
	println("expired during the delay:", decided(late), "| verifier", core.VerifierVersion(other), "| status", core.ClientStatus(other))

	// A replaced client stays recoverable (Codex docs round 5 #2): the
	// route's client, now expired, is recovered with a later client whose
	// verifier was replaced too.
	cs := ethtesting.ClientState()
	cs.LatestSlot, cs.LatestExecutionBlockNumber = 5_000_000, 5_000_000
	cs.ForkParameters = fp // the subject's schedule, migrated above
	cons := ethtesting.ConsensusState()
	cons.Slot = 5_000_000
	substitute := core.CreateClient(cross(cur), cs, cons)
	core.RegisterCounterparty(cross(cur), substitute, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), substitute, ethtesting.NextVersion)))
	println("subject:", core.ClientStatus(client), core.VerifierVersion(client), "| substitute:", core.ClientStatus(substitute), core.VerifierVersion(substitute))
	recovery := govern(cur, ibcgov.NewRecoverClientRequest(cross(cur), client, substitute))
	execute(cur, recovery)
	println("recovery:", decided(recovery), "| subject now", core.ClientStatus(client), core.VerifierVersion(client), core.ClientLatestHeight(client))
}

// Output:
// before: verifier ethereum/v0 | proves the receipt: true
// under impl/v1: spent - spent: core impl v1 converts no ethereum/v0 verifier to ethereum/testing-next | verifier ethereum/v0
// under v1-next: applied - core migrate client: route ethereum-1's meters emptied
// after: verifier ethereum/testing-next | same client: ethereum | status Active | trust generation advanced: true | payouts epoch 0 -> 1
// proves the receipt at the pre-replacement height: true | renders its state: true
// again: spent - spent: core impl v1-next converts no ethereum/testing-next verifier to ethereum/testing-next
// fork schedule on the converted verifier: applied - core migrate client: route ethereum-1's meters emptied | still ethereum/testing-next | proves the receipt: true
// expired during the delay: applied - core migrate client | verifier ethereum/testing-next | status Expired
// subject: Expired ethereum/testing-next | substitute: Active ethereum/testing-next
// recovery: applied - core recover client | subject now Active ethereum/testing-next 0/5000000
