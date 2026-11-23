// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
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

// client creates the gno client id of chain chainID (its id predicted)
// whose router committed the notices.
func client(cur realm, chainID uint64, id, counterparty string, notices ...types.Packet) *sent {
	r := ethtesting.NewRouter()
	for _, p := range notices {
		r.CommitPacket(p)
	}
	cs := ethtesting.ClientState()
	cs.ChainID = chainID
	got := core.CreateClient(cross(cur), cs, ethtesting.ConsensusStateWithRoot(r.StateRoot()))
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
		core.RecvPacket(cross(cur), types.MsgRecvPacket{Packet: p, ProofHeight: types.NewHeight(0, 72), ProofCommitment: s.router.Proof()})
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

func epochs(a, b string) string {
	return "A epoch " + string(rune('0'+ibcgov.Epoch(a))) + " over " + ibcgov.EpochClient(a) +
		" | B epoch " + string(rune('0'+ibcgov.Epoch(b))) + " over " + ibcgov.EpochClient(b)
}

// Two routes whose counterparties use the same router client ids (ADR 0007
// §2, §3): each route's kind 10 makes its own transition expected, in its
// own graph; a notice over a route's local client moves that route's epoch
// only; a route replacement retires its own clients only; decisions after a
// switch go over each route's own epoch client.
func main(cur realm) {
	client(cur, 1, "ethereum-1", "client-0")
	client(cur, 2, "ethereum-2", "client-0")
	client(cur, 1, "ethereum-3", "gnoland-b")
	nextB := client(cur, 2, "ethereum-4", "gnoland-b", noticePacket(1, "gnoland-b", "ethereum-4", 2, "gnoland-b"))
	a, b := "ethereum-1", "ethereum-2"
	// Three more successors on A's chain, to fill client-0's place on A.
	for _, n := range []string{"5", "6", "7"} {
		client(cur, 1, "ethereum-"+n, "gnoland-p"+n)
	}
	client(cur, 1, "ethereum-8", "gnoland-q")
	// A's second step, whose notice comes two epochs on.
	nextC := client(cur, 1, "ethereum-9", "gnoland-c", noticePacket(1, "gnoland-c", "ethereum-9", 3, "gnoland-c"))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), a, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), b, string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), a, a)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), b, b)))
	println(epochs(a, b))

	// Each route's kind 10, the same router client ids: client-0 to
	// gnoland-b, carried here by each route's own local client. The other
	// route's local client is not one of this route's.
	println("A's kind 10 over B's next client:", revive(func() {
		govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), a, "client-0", "gnoland-b", 1, "ethereum-4"))
	}))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), a, "client-0", "gnoland-b", 1, "ethereum-3"))
	expA := ibcgov.LastDecision()
	for _, n := range []string{"5", "6", "7"} {
		govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), a, "client-0", "gnoland-p"+n, 1, "ethereum-"+n))
	}
	println("A's client-0 full:", revive(func() {
		govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), a, "client-0", "gnoland-q", 1, "ethereum-8"))
	}))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), a, "gnoland-b", "gnoland-c", 1, "ethereum-9"))
	expC := ibcgov.LastDecision()
	// B's graph is its own: its client-0 takes a successor.
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), b, "client-0", "gnoland-b", 1, "ethereum-4"))
	expB := ibcgov.LastDecision()
	println("B's kind 10 from its own client-0:", decided(expB-1), "| A's and B's expectations:", decided(expA), "|", decided(expB))
	println("route of each expectation:", ibcgov.DecisionRoute(expA) == a, ibcgov.DecisionRoute(expB) == b)
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), expA)
	ibcgov.Execute(cross(cur), expB)
	ibcgov.Execute(cross(cur), expC)

	// A's notice two epochs on is proven over A's client; a path through B's
	// client, which A's graph does not hold, is refused; A's own path moves
	// A's epoch, never B's.
	println("A's notice, 2 steps on:", deliver(cur, nextC, 0), "|", epochs(a, b))
	println("a path through B's client:", revive(func() {
		ibcgov.ApplyEpochNotice(cross(cur), 3, "ethereum-9", "gnoland-b/ethereum-4,gnoland-c/ethereum-9")
	}), "|", epochs(a, b))
	ibcgov.ApplyEpochNotice(cross(cur), 3, "ethereum-9", "gnoland-b/ethereum-3,gnoland-c/ethereum-9")
	println("A's path:", epochs(a, b))
	// A's route replacement retires A's old client only.
	repl := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), a, "ethereum-9", 0))
	execute(cur, repl)
	println("A's replacement:", decided(repl))
	println("A's old client retired for transfers:", core.IsClientRetiredFor(a, "transfer"), "| B's client retired:", core.IsClientRetiredAny(b))
	// Decisions go over each route's own epoch client.
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), a, 2, ""))
	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), b, 2, ""))
	println("A dispatched epoch 3 seq", ibcgov.LastSeq(a, 3), "| B epoch 1 seq", ibcgov.LastSeq(b, 1))
	println("B's notice:", deliver(cur, nextB, 0), "|", epochs(a, b))
	_, permanent := ibcgov.ClientRoute("ethereum-4")
	route, _ := ibcgov.ClientRoute("ethereum-4")
	println("B's new client is B's:", route == b, permanent)
}

// Output:
// A epoch 1 over ethereum-1 | B epoch 1 over ethereum-2
// A's kind 10 over B's next client: ibcgov: ethereum-4 does not authenticate the governance route's identity
// A's client-0 full: ibcgov: router client client-0 has 4 expected successors already, intents included
// B's kind 10 from its own client-0: applied - dispatched as epoch 1 seq 1; its transition is expected from decision 16 | A's and B's expectations: pending - queued 7 days | pending - queued 7 days
// route of each expectation: true true
// A's notice, 2 steps on: error acknowledgement | A epoch 1 over ethereum-1 | B epoch 1 over ethereum-2
// a path through B's client: ibcgov: step 1, client-0 -> gnoland-b over ethereum-4, is no expected transition | A epoch 1 over ethereum-1 | B epoch 1 over ethereum-2
// A's path: A epoch 3 over ethereum-9 | B epoch 1 over ethereum-2
// A's replacement: applied - replace: client ethereum-1 retired, meters emptied
// A's old client retired for transfers: true | B's client retired: false
// A dispatched epoch 3 seq 1 | B epoch 1 seq 2
// B's notice: acknowledged | A epoch 3 over ethereum-9 | B epoch 2 over ethereum-4
// B's new client is B's: true true
