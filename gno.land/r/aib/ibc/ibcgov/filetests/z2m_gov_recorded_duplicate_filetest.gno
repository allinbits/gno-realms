// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/binary"
	"strconv"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

var govRoute, client string

func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

func payload(body []byte) types.Payload {
	return types.Payload{SourcePort: ibcgov.GovPort, DestinationPort: ibcgov.GovDestPort, Version: ibcgov.GovVersion, Encoding: ibcgov.GovEncoding, Value: body}
}

func appAck(seq uint64, status byte) []byte {
	b := binary.BigEndian.AppendUint32(nil, 1)
	b = binary.BigEndian.AppendUint64(b, seq)
	return append(b, status, 0)
}

func ack(cur realm, seq uint64, a []byte) {
	transport := ibcgov.DispatchTransport(govRoute, 1, seq)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/ibc/core"))
	var app ibcgov.App
	if err := app.OnAcknowledgementPacket(cross(cur), client, "client-0", transport, a, payload(ibcgov.DispatchBody(govRoute, 1, seq))); err != nil {
		panic(err)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func show(seq uint64) {
	status, redispatch, inFlight, sends, event := ibcgov.DispatchState(govRoute, 1, seq)
	burned, to, from := ibcgov.DispatchRebind(govRoute, 1, seq)
	println("  seq", seq, "status", status, "burned", burned, "rebound to", to, "from", from, "redispatch", redispatch, "in flight", inFlight, "sends", sends, "-", event)
}

func rebind(cur realm, from, to uint64) string {
	var got []uint64
	if r := revive(func() { got = ibcgov.Rebind(cross(cur), govRoute, 1, from, to) }); r != nil {
		return r.(string)
	}
	s := "bound"
	for _, n := range got {
		s += " " + strconv.FormatUint(n, 10)
	}
	return s
}

func settings(cur realm, i int) {
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", uint64(3600+i)))
}

// A known head left behind by out-of-order delivery moves on through
// re-sends (status 7, a duplicate of a recorded decision): 2 to 64 arrive
// buffered, 1 is recorded (and IBCAdmin drains through 64 without a word),
// 65 arrives buffered; the next decision is refused until anyone re-sends
// 2 to 65, each answered 7, and the head reads 65.
func main(cur realm) {
	client = core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	govRoute = client
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(ibcgov.Governor()), "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003")))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), govRoute, client)))

	_, _, st, _, ok := ibcgov.ParseAck(appAck(1, ibcgov.StatusDuplicateRecorded))
	println("status 7 parses:", ok, st)
	for i := 1; i <= 64; i++ {
		settings(cur, i)
	}
	for s := uint64(2); s <= 64; s++ {
		ack(cur, s, appAck(s, ibcgov.StatusBuffered))
	}
	ack(cur, 1, appAck(1, ibcgov.StatusRecorded))
	settings(cur, 65)
	ack(cur, 65, appAck(65, ibcgov.StatusBuffered))
	println("known head", ibcgov.KnownHead(govRoute, 1), "last seq", ibcgov.LastSeq(govRoute, 1))
	println("66:", revive(func() { settings(cur, 66) }))
	for s := uint64(2); s <= 65; s++ {
		ibcgov.Redispatch(cross(cur), govRoute, 1, s)
		ack(cur, s, appAck(s, ibcgov.StatusDuplicateRecorded))
	}
	println("known head", ibcgov.KnownHead(govRoute, 1))
	show(2)
	settings(cur, 66)
	println("66 bound:", ibcgov.LastSeq(govRoute, 1))

	// A 7 keeps a recorded, spent or conflicting status, as a 3 does, and a
	// 6 stays final.
	ack(cur, 1, appAck(1, ibcgov.StatusDuplicateRecorded))
	show(1)
	ack(cur, 66, appAck(66, ibcgov.StatusConflict))
	ack(cur, 66, appAck(66, ibcgov.StatusDuplicateRecorded))
	show(66)
	settings(cur, 67)
	ack(cur, 67, appAck(67, ibcgov.StatusCancelled))
	ack(cur, 67, appAck(67, ibcgov.StatusDuplicateRecorded))
	show(67)
}

// Output:
// status 7 parses: true 7
// known head 1 last seq 65
// 66: ibcgov: Ethereum has recorded up to 1 in epoch 1; at most 64 decisions ahead of it: retry once acknowledgements catch up
// known head 65
//   seq 2 status 1 burned false rebound to 0 from 0 redispatch false in flight false sends 2 - acknowledged: recorded (a duplicate of a recorded decision)
// 66 bound: 66
//   seq 1 status 1 burned false rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: duplicate of a decision recorded, recorded there
//   seq 66 status 4 burned false rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: duplicate of a decision conflict, recorded there
//   seq 67 status 6 burned true rebound to 0 from 0 redispatch false in flight false sends 1 - acknowledged: duplicate of a recorded decision after the cancellation, which stands
