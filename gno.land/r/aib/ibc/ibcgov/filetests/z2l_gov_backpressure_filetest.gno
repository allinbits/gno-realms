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

// gno.land's backpressure (ADR 0004, "Burned numbers and Rebind"): no
// Ethereum-bound decision but a cancel is bound more than 64 numbers past
// the highest one IBCAdmin acknowledged recording, so a cancel of any
// dispatched number lands inside IBCAdmin's horizon (its last recorded
// number plus 64) whenever it arrives, and its tombstone is never dropped.
func main(cur realm) {
	client = core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	govRoute = client
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(ibcgov.Governor()), "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003")))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), govRoute, client)))

	// Head 0: seqs 1 to 63 go out, none acknowledged.
	for i := 1; i <= 63; i++ {
		settings(cur, i)
	}
	// A request built now, with room for one more, recorded once there is
	// none: spent at recording, nothing bound.
	late := ibcgov.NewEthRouteSettingsRequest(cross(cur), govRoute, "client-0", 99999)
	settings(cur, 64)
	println("known head", ibcgov.KnownHead(govRoute, 1), "last seq", ibcgov.LastSeq(govRoute, 1))
	println("the 65th, built:", revive(func() { settings(cur, 65) }))
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), late)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	d, _ := ibcgov.Decision(ibcgov.LastDecision())
	println("the 65th, recorded:", d.State(), "-", d.Note)
	println("last seq", ibcgov.LastSeq(govRoute, 1))
	// A cancel is exempt: its own number may lie beyond the window.
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), govRoute, "64"))
	println("a cancel binds at", ibcgov.LastSeq(govRoute, 1))

	// Duplicates and buffered answers say nothing of IBCAdmin's head;
	// recorded ones do.
	ack(cur, 3, appAck(3, ibcgov.StatusBuffered))
	ack(cur, 2, appAck(2, ibcgov.StatusDuplicate))
	println("known head after 2 and 3:", ibcgov.KnownHead(govRoute, 1))
	for s := uint64(1); s <= 10; s++ {
		ack(cur, s, appAck(s, ibcgov.StatusRecorded))
	}
	println("known head", ibcgov.KnownHead(govRoute, 1))
	settings(cur, 66)
	n := ibcgov.LastSeq(govRoute, 1)
	println("bound at", n, "; within the horizon of head 10:", n <= ibcgov.KnownHead(govRoute, 1)+64)
	// Our cancel of it lands inside IBCAdmin's horizon, whenever it arrives:
	// IBCAdmin's head is at least 10.
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), govRoute, strconv.FormatUint(n, 10)))
	println("cancelled", n, "inside the horizon:", n <= ibcgov.KnownHead(govRoute, 1)+ibcgov.GovWindow)

	// Rebind's copies obey the bound: seq 11 burned (head 11), the epoch
	// filled up to head + 64, and the copy refused.
	ack(cur, 11, appAck(11, ibcgov.StatusCancelled))
	for ibcgov.LastSeq(govRoute, 1) < ibcgov.KnownHead(govRoute, 1)+64 {
		settings(cur, int(ibcgov.LastSeq(govRoute, 1))+100)
	}
	println("last seq", ibcgov.LastSeq(govRoute, 1), "known head", ibcgov.KnownHead(govRoute, 1))
	println("rebind 11:", rebind(cur, 11, 11))
	ack(cur, 12, appAck(12, ibcgov.StatusRecorded))
	println("rebind 11 once 12 is recorded:", rebind(cur, 11, 11))
}

// Output:
// known head 0 last seq 64
// the 65th, built: ibcgov: Ethereum has recorded up to 0 in epoch 1; at most 64 decisions ahead of it: retry once acknowledgements catch up
// the 65th, recorded: spent - spent: Ethereum has recorded up to 0 in epoch 1; at most 64 decisions ahead of it: retry once acknowledgements catch up
// last seq 64
// a cancel binds at 65
// known head after 2 and 3: 0
// known head 10
// bound at 66 ; within the horizon of head 10: true
// cancelled 66 inside the horizon: true
// last seq 75 known head 11
// rebind 11: ibcgov: Ethereum has recorded up to 11 in epoch 1; at most 64 decisions ahead of it: retry once acknowledgements catch up
// rebind 11 once 12 is recorded: bound 76
