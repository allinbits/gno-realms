// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/controls/v0"
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

const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var (
	collector = testutils.TestAddress("collector")
	g0        = testutils.TestAddress("g0")
	g1        = testutils.TestAddress("g1")
)

func flagAs(cur realm, who address, route, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.SetFlag(cross(cur), route, fn, "")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func clearAs(cur realm, who address, route, fn string) {
	testing.SetRealm(testing.NewUserRealm(who))
	ibcgov.ClearFlag(cross(cur), route, fn)
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
	height       uint64 // the slot of the consensus state the proofs are read at (72 by default)
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

// healthyClient is client with its latest slot far ahead, so it stays
// Active when the block time jumps.
func healthyClient(cur realm, id, counterparty string, notices ...types.Packet) *sent {
	r := ethtesting.NewRouter()
	for _, p := range notices {
		r.CommitPacket(p)
	}
	cs := ethtesting.ClientState()
	cs.LatestSlot, cs.LatestExecutionBlockNumber = far, far
	cons := ethtesting.ConsensusStateWithRoot(r.StateRoot())
	cons.Slot = far
	got := core.CreateClient(cross(cur), cs, cons)
	if got != id {
		panic("client " + got + ", not " + id)
	}
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, counterparty)
	return &sent{counterparty: counterparty, notices: notices, router: r, height: far}
}

const far = 5_000_000 // slots; one is 2 s

func setTime(t time.Time) {
	ctx := testing.GetContext()
	ctx.Time = t
	testing.SetContext(ctx)
}

func controlsView() controls.Reader { return transfer.ExtView("controls").(controls.Reader) }

const freezeImpl = "gno.land/r/aib/ibc/core/impl/v1freeze"

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
		core.RecvPacket(cross(cur), types.MsgRecvPacket{Packet: p, ProofHeight: types.NewHeight(0, proofSlot(s)), Ext: extproof.Proof{Data: s.router.Proof()}})
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

func proofSlot(s *sent) uint64 {
	if s.height != 0 {
		return s.height
	}
	return 72
}

func epochNow() string {
	return "epoch " + strconv.FormatUint(uint64(ibcgov.Epoch()), 10) + " over " + ibcgov.EpochClient()
}

// plain creates an Ethereum client whose counterparty is the router client
// remote, and returns its id.
func plain(cur realm, remote string) string {
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, remote)
	return id
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

// Retention covers the whole bounded graph (Codex round 42 #3): in a chain
// client-0 → a1 → … → a18, the client of a17 (17 steps on) is on the
// expected graph, so its route replacement retires it for transfers only;
// after a1's notice a17 is 16 steps on, and its notice, applied with its
// path, moves the epoch there.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	a1 := client(cur, "ethereum-2", "gnoland-a1", noticePacket(1, "gnoland-a1", "ethereum-2", 2, "gnoland-a1"))
	var a17 *sent
	for i := 2; i <= 18; i++ {
		r := "gnoland-a" + strconv.Itoa(i)
		id := "ethereum-" + strconv.Itoa(i+1)
		if i == 17 {
			a17 = client(cur, id, r, noticePacket(1, r, id, 18, r))
		} else {
			client(cur, id, r)
		}
	}
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	prev := "client-0"
	for i := 1; i <= 18; i++ {
		r := "gnoland-a" + strconv.Itoa(i)
		kind10(cur, prev, r, 1, "ethereum-"+strconv.Itoa(i+1))
		prev = r
	}
	expectAll(cur)
	// The route moves to a17's client, then on: a17's client, 17 steps on,
	// is retired for transfers only.
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", "ethereum-18", 0)))
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", plain(cur, "gnoland-r"), 0)))
	println("a17's client retired for transfers:", core.IsClientRetiredFor("ethereum-18", "transfer"), "| for governance:", core.IsClientRetiredFor("ethereum-18", ibcgov.GovPort))
	println("a1's notice:", deliver(cur, a1, 0), "|", epochNow())
	println("a17's notice, 16 steps on:", deliver(cur, a17, 0), "|", epochNow())
	var path []string
	for i := 2; i <= 17; i++ {
		path = append(path, "gnoland-a"+strconv.Itoa(i)+"/ethereum-"+strconv.Itoa(i+1))
	}
	ibcgov.ApplyEpochNotice(cross(cur), 18, "ethereum-18", strings.Join(path, ","))
	println("applied:", epochNow())
}

// Output:
// a17's client retired for transfers: true | for governance: false
// a1's notice: acknowledged | epoch 2 over ethereum-2
// a17's notice, 16 steps on: error acknowledgement | epoch 2 over ethereum-2
// applied: epoch 18 over ethereum-18
