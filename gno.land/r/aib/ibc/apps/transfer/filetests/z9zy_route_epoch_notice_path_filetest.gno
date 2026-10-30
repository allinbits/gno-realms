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

var collector = testutils.TestAddress("collector")

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

// pendingExpect is the expectation decisions the kind 10s dispatched so far
// recorded (each waits 7 days); expectAll applies them.
var pendingExpect []int64

func kind10(cur realm, from, to string, suspectFrom uint64, local string) {
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), from, to, suspectFrom, local))
	pendingExpect = append(pendingExpect, ibcgov.LastDecision())
}

func expectAll(cur realm) {
	advance(7*24*time.Hour + time.Second)
	for _, id := range pendingExpect {
		ibcgov.Execute(cross(cur), id)
	}
	pendingExpect = nil
}

// A notice several steps on, over a branching graph of expected transitions
// (Codex round 35 #2): client-0 → {b1, b2}, b1 → {c1, c2}, c1 → {d1, d2},
// d1 → e1, each over its approved local client. Ethereum executed
// client-0 → b1 → c1 → d1 → e1, and the notices of b1, c1 and d1 were never
// relayed (their clients failed). e1's notice, four steps on, is recorded
// as proven over e1's client; anyone applies it with its path, checked step
// by step in O(k), whatever the graph's branching. A path through another
// branch, or naming another local client, is refused.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	for i, r := range []string{"gnoland-b1", "gnoland-b2", "gnoland-c1", "gnoland-c2", "gnoland-d1", "gnoland-d2"} {
		client(cur, "ethereum-"+strconv.Itoa(i+2), r)
	}
	e1 := client(cur, "ethereum-8", "gnoland-e1", noticePacket(1, "gnoland-e1", "ethereum-8", 5, "gnoland-e1"))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	for _, t := range [][3]string{
		{"client-0", "gnoland-b1", "ethereum-2"}, {"client-0", "gnoland-b2", "ethereum-3"},
		{"gnoland-b1", "gnoland-c1", "ethereum-4"}, {"gnoland-b1", "gnoland-c2", "ethereum-5"},
		{"gnoland-c1", "gnoland-d1", "ethereum-6"}, {"gnoland-c1", "gnoland-d2", "ethereum-7"},
		{"gnoland-d1", "gnoland-e1", "ethereum-8"},
	} {
		kind10(cur, t[0], t[1], 1, t[2])
	}
	expectAll(cur)
	println(epochNow())
	println("e1's notice:", deliver(cur, e1, 0), "|", epochNow())
	for _, path := range []string{
		"gnoland-b2/ethereum-3,gnoland-c1/ethereum-4,gnoland-d1/ethereum-6,gnoland-e1/ethereum-8",
		"gnoland-b1/ethereum-2,gnoland-c1/ethereum-5,gnoland-d1/ethereum-6,gnoland-e1/ethereum-8",
		"gnoland-b1/ethereum-2,gnoland-c1/ethereum-4,gnoland-d1/ethereum-6",
	} {
		println("path", path+":", revive(func() { ibcgov.ApplyEpochNotice(cross(cur), 5, "ethereum-8", path) }))
	}
	ibcgov.ApplyEpochNotice(cross(cur), 5, "ethereum-8", "gnoland-b1/ethereum-2,gnoland-c1/ethereum-4,gnoland-d1/ethereum-6,gnoland-e1/ethereum-8")
	println("applied:", epochNow(), "| the old client retired for governance:", core.IsClientRetiredFor("ethereum-1", ibcgov.GovPort))
	println("applied again:", revive(func() {
		ibcgov.ApplyEpochNotice(cross(cur), 5, "ethereum-8", "gnoland-b1/ethereum-2,gnoland-c1/ethereum-4,gnoland-d1/ethereum-6,gnoland-e1/ethereum-8")
	}))
}

// Output:
// epoch 1 over ethereum-1
// e1's notice: error acknowledgement | epoch 1 over ethereum-1
// path gnoland-b2/ethereum-3,gnoland-c1/ethereum-4,gnoland-d1/ethereum-6,gnoland-e1/ethereum-8: ibcgov: step 2, gnoland-b2 -> gnoland-c1 over ethereum-4, is no expected transition
// path gnoland-b1/ethereum-2,gnoland-c1/ethereum-5,gnoland-d1/ethereum-6,gnoland-e1/ethereum-8: ibcgov: step 2, gnoland-b1 -> gnoland-c1 over ethereum-5, is no expected transition
// path gnoland-b1/ethereum-2,gnoland-c1/ethereum-4,gnoland-d1/ethereum-6: ibcgov: the path names 3 transitions, not 4
// applied: epoch 5 over ethereum-8 | the old client retired for governance: true
// applied again: ibcgov: no epoch notice of epoch 5 was proven over ethereum-8
