// PKGPATH: gno.land/r/aib/main
package main

import (
	"math"
	"strconv"
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

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
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector), bridge)))
	advance(7*24*time.Hour + time.Second) // keeps the timeline of the goldens
	return clientID
}

// ethPacket is a transfer packet the Ethereum router sent to client.
func ethPacket(client string, seq uint64, token, receiver string, amount int64, timeout uint64) types.Packet {
	data := ics20.NewFungibleTokenPacketData(token, strconv.FormatInt(amount, 10), ethReceiver, receiver, "")
	bz, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	return types.Packet{
		Sequence: seq, SourceClient: "client-0", DestinationClient: client, TimeoutTimestamp: timeout,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}},
	}
}

// relay delivers p through the core with a proof of the router's commitment.
func relay(cur realm, router *ethtesting.Router, p types.Packet) {
	core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet: p, ProofHeight: types.NewHeight(0, 72), Ext: extproof.Proof{Data: router.Proof()},
	})
}

func controlsView() controls.Reader { return transfer.ExtView("controls").(controls.Reader) }

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// A receive that would overflow what the route owes is refused with an
// error acknowledgement through the core, before anything is booked (Codex
// round 12 #4): CheckCredit makes Credit's own checked addition.
func main(cur realm) {
	const client = "ethereum-1"
	timeout := uint64(time.Now().Add(90 * 24 * time.Hour).Unix())
	big := ethPacket(client, 1, "transfer/client-0/ugnot", bob.String(), math.MaxInt64, timeout) // above the free lock: swept
	one := ethPacket(client, 2, "transfer/client-0/ugnot", bob.String(), 1, timeout)
	router := ethtesting.NewRouter()
	router.CommitPacket(big)
	router.CommitPacket(one)
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), client, "ugnot", "unescrow", 10_000, 0, 20, 2, 25_000, 40, 10_000, "0x0000000000000000000000000000000000c0ffee")))

	relay(cur, router, big)
	t, _ := controlsView().Totals(client, "ugnot")
	println("swept:", t.Swept)
	relay(cur, router, one)
	errAck := types.CommitAcknowledgement(types.Acknowledgement{AppAcknowledgements: [][]byte{types.UniversalErrorAcknowledgement()}})
	_, booked := controlsView().Sweep(client, controls.PacketKey(client, 2))
	println("error ack:", string(core.PacketAcknowledgement(client, 2)) == string(errAck), "| booked:", booked)
}

// Output:
// swept: 9223372036854775807
// error ack: true | booked: false
