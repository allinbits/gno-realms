// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
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

// expectNow records a recovery expectation and returns its decision.
func expectNow(cur realm, from, to, local string) int64 {
	return govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), from, to, local))
}

// junk records a recovery expectation and cancels it: a tombstone.
func junk(cur realm, from, to, local string) {
	govern(cur, ibcgov.NewCancelRequest(cross(cur), expectNow(cur, from, to, local)))
}

// approveAll executes the decisions after their 7 days.
func approveAll(cur realm, ids ...int64) {
	advance(7*24*time.Hour + time.Second)
	for _, id := range ids {
		ibcgov.Execute(cross(cur), id)
	}
}

func r(i int) string  { return "gnoland-r" + strconv.Itoa(i) }
func rl(i int) string { return "ethereum-" + strconv.Itoa(i+1) }

// Nested tombstones survive an epoch switch that still reaches them (code
// review r48 #2): A→B→C→D expected, C→D and B→C removed, the route moved
// past D here. B's notice switches the epoch; the switch keeps B→C's and
// C→D's tombstones (reached through B→C's), so a prune retires neither C
// nor D; B→C and C→D are approved again and C's and D's notices apply.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	b := client(cur, "ethereum-2", "gnoland-b", noticePacket(1, "gnoland-b", "ethereum-2", 2, "gnoland-b"))
	c := client(cur, "ethereum-3", "gnoland-c", noticePacket(1, "gnoland-c", "ethereum-3", 3, "gnoland-c"))
	d := client(cur, "ethereum-4", "gnoland-d", noticePacket(1, "gnoland-d", "ethereum-4", 4, "gnoland-d"))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	kind10(cur, "client-0", "gnoland-b", 1, "ethereum-2")
	kind10(cur, "gnoland-b", "gnoland-c", 1, "ethereum-3")
	kind10(cur, "gnoland-c", "gnoland-d", 1, "ethereum-4")
	expectAll(cur)
	println("remove C→D:", decided(govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "gnoland-c", "gnoland-d", "ethereum-4"))))
	println("remove B→C:", decided(govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "gnoland-b", "gnoland-c", "ethereum-3"))))
	for _, next := range []string{"ethereum-2", "ethereum-3", "ethereum-4"} {
		execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", next, 0)))
	}
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", plain(cur, "gnoland-r"), 0)))
	println("B's notice:", deliver(cur, b, 0), "|", epochNow(), "| tombstones:", ibcgov.Tombstones())
	println("pruned:", ibcgov.PruneGovRetirements(cross(cur), 64))
	for _, id := range []string{"ethereum-3", "ethereum-4"} {
		println(id, "retired for transfers:", core.IsClientRetiredFor(id, "transfer"), "| for governance:", core.IsClientRetiredFor(id, ibcgov.GovPort))
	}
	approveAll(cur, expectNow(cur, "gnoland-b", "gnoland-c", "ethereum-3"), expectNow(cur, "gnoland-c", "gnoland-d", "ethereum-4"))
	println("approved again | tombstones:", ibcgov.Tombstones())
	println("C's notice:", deliver(cur, c, 0), "|", epochNow())
	println("D's notice:", deliver(cur, d, 0), "|", epochNow())
}

// Output:
// remove C→D: applied - no longer expect the governance epoch to move from gnoland-c to gnoland-d over ethereum-4
// remove B→C: applied - no longer expect the governance epoch to move from gnoland-b to gnoland-c over ethereum-3
// B's notice: acknowledged | epoch 2 over ethereum-2 | tombstones: 2
// pruned: 0
// ethereum-3 retired for transfers: true | for governance: false
// ethereum-4 retired for transfers: true | for governance: false
// approved again | tombstones: 0
// C's notice: acknowledged | epoch 3 over ethereum-3
// D's notice: acknowledged | epoch 4 over ethereum-4
