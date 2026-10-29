// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
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

// A notice with no path of the length it needs pins nothing (code review
// r46 #1): Ethereum executes recoveries A→X→Y→C, reaching epoch 4. Before
// C's notice arrives, governance removed A→X and filled A's four successors
// with branches A→Bi→C, so C is only two steps away. C's notice, three
// steps on, is recorded as proven over C's healthy client: it pins none of
// the two-step branches, so one is removed, A→X is expected again, a
// transition on the three-step path is then pinned, and the notice applies.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	client(cur, "ethereum-2", "gnoland-x")
	client(cur, "ethereum-3", "gnoland-y")
	c := client(cur, "ethereum-4", "gnoland-c", noticePacket(1, "gnoland-c", "ethereum-4", 4, "gnoland-c"))
	for i := 1; i <= 4; i++ {
		client(cur, "ethereum-"+strconv.Itoa(i+4), "gnoland-b"+strconv.Itoa(i))
	}
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	expectAll := func(reqs ...func() ibcgov.Request) {
		var ids []int64
		for _, r := range reqs {
			ids = append(ids, govern(cur, r()))
		}
		advance(7*24*time.Hour + time.Second)
		for _, id := range ids {
			ibcgov.Execute(cross(cur), id)
		}
	}
	expect := func(from, to, local string) func() ibcgov.Request {
		return func() ibcgov.Request { return ibcgov.NewExpectRecoveryRequest(cross(cur), from, to, local) }
	}
	expectAll(expect("client-0", "gnoland-x", "ethereum-2"), expect("gnoland-x", "gnoland-y", "ethereum-3"), expect("gnoland-y", "gnoland-c", "ethereum-4"))
	println("remove A→X:", decided(govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "client-0", "gnoland-x", "ethereum-2"))))
	var reqs []func() ibcgov.Request
	for i := 1; i <= 4; i++ {
		b := "gnoland-b" + strconv.Itoa(i)
		reqs = append(reqs, expect("client-0", b, "ethereum-"+strconv.Itoa(i+4)), expect(b, "gnoland-c", "ethereum-4"))
	}
	expectAll(reqs...)
	println("C's notice, 3 steps on:", deliver(cur, c, 0), "|", epochNow())
	println("A→X again, successors full:", revive(func() {
		govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-x", "ethereum-2"))
	}))
	println("remove A→B1 (on no 3-step path):", decided(govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "client-0", "gnoland-b1", "ethereum-5"))))
	expectAll(expect("client-0", "gnoland-x", "ethereum-2"))
	println("remove X→Y (on the 3-step path):", revive(func() {
		govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "gnoland-x", "gnoland-y", "ethereum-3"))
	}))
	println("remove B2→C (on no 3-step path):", decided(govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "gnoland-b2", "gnoland-c", "ethereum-4"))))
	ibcgov.ApplyEpochNotice(cross(cur), 4, "ethereum-4", "gnoland-x/ethereum-2,gnoland-y/ethereum-3,gnoland-c/ethereum-4")
	println("applied:", epochNow())
}

// Output:
// remove A→X: applied - no longer expect the governance epoch to move from client-0 to gnoland-x over ethereum-2
// C's notice, 3 steps on: error acknowledgement | epoch 1 over ethereum-1
// A→X again, successors full: ibcgov: router client client-0 has 4 expected successors already, intents included
// remove A→B1 (on no 3-step path): applied - no longer expect the governance epoch to move from client-0 to gnoland-b1 over ethereum-5
// remove X→Y (on the 3-step path): ibcgov: a notice proven over ethereum-4 may need the transition: apply it or let it lapse first
// remove B2→C (on no 3-step path): applied - no longer expect the governance epoch to move from gnoland-b2 to gnoland-c over ethereum-4
// applied: epoch 4 over ethereum-4
