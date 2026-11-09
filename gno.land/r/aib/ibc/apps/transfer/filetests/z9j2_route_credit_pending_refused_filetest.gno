// PKGPATH: gno.land/r/aib/ibc/apps/transfer/impl/asyncrecv
package asyncrecv

import (
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
	controlsimpl "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
	ics20impl "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const self = "gno.land/r/aib/ibc/apps/transfer/impl/asyncrecv"

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	bob       = testutils.TestAddress("bob")
)

const (
	ethReceiver = "0x5f67a5398d91087d1b37a8a43436196a7830867f"
	weth        = "0x457df1a9866af7b6a78eeba9291fc3e58b4d864b"
)

// async is a test implementation keeping the route controls (impl/controls/v0
// around the plain app) that answers every receive asynchronously: no
// implementation does so today (ADR 0004, Known limits), so this is the only
// way to leave a route's packet with its acknowledgement pending.
type async struct {
	transfer.Logic
	transfer.ControlsLogic
}

func (async) Version() string { return "v1" }

func (async) OnRecvPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult {
	return types.RecvPacketResult{Status: types.PacketStatus_Async}
}

func newAsync(s transfer.Store) transfer.Logic {
	l := controlsimpl.New(ics20impl.New(s), s)
	return async{Logic: l, ControlsLogic: l.(transfer.ControlsLogic)}
}

func init(cur realm) {
	transfer.RegisterImpl(cross(cur), newAsync, "v1", nil, true)
}

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
	testing.SetRealm(testing.NewCodeRealm(self))
	return ibcgov.LastDecision()
}

// execute applies a queued decision once its 7 days have passed.
func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// A credit by vote needs the packet's success acknowledgement: one whose
// asynchronous acknowledgement is still pending is refused, nothing booked
// and the acknowledgement left to the app (review of #85: no transfer
// implementation answers asynchronously, and the controls have no path for
// it).
func main(cur realm) {
	const client = "ethereum-1"
	timeout := uint64(time.Now().Add(90 * 24 * time.Hour).Unix())
	data := ics20.NewFungibleTokenPacketData(weth, strconv.FormatInt(50, 10), ethReceiver, bob.String(), "")
	bz, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	p := types.Packet{
		Sequence: 1, SourceClient: "client-0", DestinationClient: client, TimeoutTimestamp: timeout,
		Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: abi.Encoding, Value: bz}},
	}
	router := ethtesting.NewRouter()
	router.CommitPacket(p)
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(router.StateRoot()))
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	voucher := ics20.NewDenom(weth, ics20.NewHop("transfer", client)).IBCDenom()
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewSetDenomRequest(cross(cur), client, weth, "mint", 4_000, 10_000, 10, 1, 0, 0, 4_000, "", 6)))
	switched := govern(cur, ibcgov.NewTransferUpdateImplRequest(cross(cur), self))
	execute(cur, switched)
	println("switch:", decided(switched), "| active:", transfer.ImplPath(), transfer.ImplVersion())

	core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet: p, ProofHeight: types.NewHeight(0, 72), Ext: extproof.Proof{Data: router.Proof()},
	})
	_, _, pending := core.PendingAsyncAck(client, 1)
	println("acknowledgement pending:", pending, "| voucher token:", transfer.VoucherSymbol(voucher) != "")

	credit := govern(cur, ibcgov.NewCreditRequest(cross(cur), client, controls.PacketKey(client, 1), voucher, string(bob), 50))
	execute(cur, credit)
	_, _, pending = core.PendingAsyncAck(client, 1)
	println("credit:", decided(credit))
	println("acknowledgement pending:", pending, "| voucher token:", transfer.VoucherSymbol(voucher) != "")
}

// Output:
// switch: applied - transfer update impl | active: gno.land/r/aib/ibc/apps/transfer/impl/asyncrecv v1
// acknowledgement pending: true | voucher token: false
// credit: refused - packet ethereum-1/00000000000000000001 has no success acknowledgement: an error-acknowledged packet is refunded at its source
// acknowledgement pending: true | voucher token: false
