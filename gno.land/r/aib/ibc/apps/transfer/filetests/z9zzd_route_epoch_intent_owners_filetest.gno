// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	g0        = testutils.TestAddress("g0")
	g1        = testutils.TestAddress("g1")
)

func flagAs(cur realm, who address, route, fn string, set bool) {
	testing.SetRealm(testing.NewUserRealm(who))
	if set {
		ibcgov.SetFlag(cross(cur), route, fn, "")
	} else {
		ibcgov.ClearFlag(cross(cur), route, fn)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

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

func decided(id int64) string {
	d, _ := ibcgov.Decision(id)
	return d.State() + " - " + d.Note
}

// The notices IBCAdmin sends, by gno client: the packet (from the router's
// client counterparty), committed in that client's router.
type sent struct {
	counterparty string
	notices      []types.Packet
	router       *ethtesting.Router
}

func noticePacket(seq uint64, counterparty, client string, epoch uint32, named string) types.Packet {
	return types.Packet{Sequence: seq, SourceClient: counterparty, DestinationClient: client, TimeoutTimestamp: 9_999_999_999,
		Payloads: []types.Payload{{SourcePort: ibcgov.GovDestPort, DestinationPort: ibcgov.GovPort, Version: ibcgov.GovVersion,
			Encoding: ibcgov.GovEncoding, Value: ibcgov.EpochNotice(epoch, named)}}}
}

// client creates the gno client id (its id predicted) whose router committed
// the notices.
func client(cur realm, id, counterparty string, notices ...types.Packet) *sent {
	r := ethtesting.NewRouter()
	for _, p := range notices {
		r.CommitPacket(p)
	}
	got := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusStateWithRoot(r.StateRoot()))
	if got != id {
		panic("client " + got + ", not " + id)
	}
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, counterparty)
	return &sent{counterparty: counterparty, notices: notices, router: r}
}

// deliver relays notice i of s through the core, its proof verified by the
// gno client it arrives on; it returns the acknowledgement written.
func deliver(cur realm, s *sent, i int) string {
	p := s.notices[i]
	var out string
	func() {
		defer func() {
			if r := recover(); r != nil {
				switch v := r.(type) {
				case error:
					out = "aborted: " + v.Error()
				case string:
					out = "aborted: " + v
				default:
					out = "aborted"
				}
			}
		}()
		core.RecvPacket(cross(cur), types.MsgRecvPacket{Packet: p, ProofHeight: types.NewHeight(0, 72), Ext: extproof.Proof{Data: s.router.Proof()}})
		ack := core.PacketAcknowledgement(p.DestinationClient, p.Sequence)
		switch {
		case len(ack) == 0:
			out = "no acknowledgement"
		case string(ack) == string(types.CommitAcknowledgement(types.Acknowledgement{AppAcknowledgements: [][]byte{types.UniversalErrorAcknowledgement()}})):
			out = "error acknowledgement"
		default:
			out = "acknowledged"
		}
	}()
	return out
}

func epochNow() string {
	return "epoch " + string(rune('0'+ibcgov.Epoch())) + " over " + ibcgov.EpochClient()
}

// An intent lives while one of its expectation decisions is pending (Codex
// round 41 #1): two kind 10s for the same transition A→B, one expectation
// cancelled, keep its place among A's successors, so three others fill the
// cap and a fourth is refused; the surviving expectation, executed last,
// applies and B's notice moves the epoch. The same with a kind 10 and a
// recovery expectation for one transition B→C: the kind 10's cancelled, the
// recovery's applies.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	b := client(cur, "ethereum-2", "gnoland-b", noticePacket(1, "gnoland-b", "ethereum-2", 2, "gnoland-b"))
	c := client(cur, "ethereum-3", "gnoland-c", noticePacket(1, "gnoland-c", "ethereum-3", 3, "gnoland-c"))
	client(cur, "ethereum-4", "gnoland-d")
	client(cur, "ethereum-5", "gnoland-e")
	client(cur, "ethereum-6", "gnoland-f")
	client(cur, "ethereum-7", "gnoland-g")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	dispatch := func(from, to, local string) int64 {
		govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), from, to, 1, local))
		return ibcgov.LastDecision()
	}
	first := dispatch("client-0", "gnoland-b", "ethereum-2")
	second := dispatch("client-0", "gnoland-b", "ethereum-2")
	govern(cur, ibcgov.NewCancelRequest(cross(cur), first))
	others := []int64{dispatch("client-0", "gnoland-d", "ethereum-4"), dispatch("client-0", "gnoland-e", "ethereum-5"), dispatch("client-0", "gnoland-f", "ethereum-6")}
	println("a fourth other successor:", revive(func() { dispatch("client-0", "gnoland-g", "ethereum-7") }))
	advance(7*24*time.Hour + time.Second)
	for _, id := range others {
		ibcgov.Execute(cross(cur), id)
	}
	ibcgov.Execute(cross(cur), second)
	println("the surviving expectation, executed last:", decided(second))
	println("b's notice:", deliver(cur, b, 0), "|", epochNow())

	// A kind 10 and a recovery expectation for B→C.
	byKind10 := dispatch("gnoland-b", "gnoland-c", "ethereum-3")
	govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "gnoland-b", "gnoland-c", "ethereum-3"))
	byRecovery := ibcgov.LastDecision()
	govern(cur, ibcgov.NewCancelRequest(cross(cur), byKind10))
	execute(cur, byRecovery)
	println("the recovery's expectation:", decided(byRecovery))
	println("c's notice:", deliver(cur, c, 0), "|", epochNow())
}

// Output:
// a fourth other successor: ibcgov: router client client-0 has 4 expected successors already, intents included
// the surviving expectation, executed last: applied - expect the governance epoch to move from client-0 to gnoland-b over ethereum-2
// b's notice: acknowledged | epoch 2 over ethereum-2
// the recovery's expectation: applied - expect the governance epoch to move from gnoland-b to gnoland-c over ethereum-3
// c's notice: acknowledged | epoch 3 over ethereum-3
