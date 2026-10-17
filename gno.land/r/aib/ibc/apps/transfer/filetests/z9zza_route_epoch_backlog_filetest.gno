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
	return "epoch " + string(rune('0'+ibcgov.Epoch())) + " over " + ibcgov.EpochClient()
}

// plain creates an Ethereum client whose counterparty is the router client
// remote, and returns its id.
func plain(cur realm, remote string) string {
	id := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, remote)
	return id
}

// Switching the epoch does bounded work (Codex round 36 #2). An expected
// graph whose fourth step reaches more than 64 router clients cannot be
// searched within bounds, so every client a route replacement retires then
// is kept open for governance and waits (a growing backlog). A notice's
// switch retires only the old epoch client and its path's steps, whatever
// the backlog; PruneGovRetirements retires the rest in bounded batches once
// their paths can be told, the epoch having moved to a smaller graph.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	b1 := client(cur, "ethereum-2", "gnoland-b1", noticePacket(1, "gnoland-b1", "ethereum-2", 2, "gnoland-b1"))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	expect := func(from, to, local string) {
		govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), from, to, 1, local))
	}
	// client-0 -> b1..b4 -> c.. (16) -> d.. (64) -> e.. (65)
	var level []string
	for i := 1; i <= 4; i++ {
		r := "gnoland-b" + strconv.Itoa(i)
		local := "ethereum-2"
		if i > 1 {
			local = plain(cur, r)
		}
		expect("client-0", r, local)
		level = append(level, r)
	}
	for depth, name := range []string{"c", "d"} {
		var next []string
		for pi, p := range level {
			for j := 1; j <= 4; j++ {
				r := "gnoland-" + name + strconv.Itoa(pi) + "x" + strconv.Itoa(j)
				expect(p, r, plain(cur, r))
				next = append(next, r)
			}
		}
		level = next
		_ = depth
	}
	for pi, p := range level {
		n := 1
		if pi == 0 {
			n = 2
		}
		for j := 1; j <= n; j++ {
			r := "gnoland-e" + strconv.Itoa(pi) + "x" + strconv.Itoa(j)
			expect(p, r, plain(cur, r))
		}
	}
	println(epochNow(), "| expectations recorded")

	// Route replacements now: the graph cannot be searched within bounds,
	// so each old client is retired for transfers only and waits.
	route := []string{"ethereum-1"}
	for i := 0; i < 5; i++ {
		next := plain(cur, "gnoland-r"+strconv.Itoa(i))
		execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", next, 0)))
		route = append(route, next)
	}
	println("waiting:", ibcgov.AwaitingGovRetirement())

	// The notice switches the epoch to b1, retiring only the old epoch
	// client: the backlog is left for the batches.
	println("b1's notice:", deliver(cur, b1, 0), "|", epochNow())
	retired := 0
	for _, c := range route[1 : len(route)-1] {
		if core.IsClientRetiredFor(c, ibcgov.GovPort) {
			retired++
		}
	}
	println("old epoch client retired:", core.IsClientRetired("ethereum-1"), "| backlog clients retired by the switch:", retired, "| waiting:", ibcgov.AwaitingGovRetirement())
	println("pruned:", ibcgov.PruneGovRetirements(cross(cur), 2), "| waiting:", ibcgov.AwaitingGovRetirement())
	println("pruned:", ibcgov.PruneGovRetirements(cross(cur), 64), "| waiting:", ibcgov.AwaitingGovRetirement())
	println("a replaced route client retired for good:", core.IsClientRetired(route[2]))
}

// Output:
// epoch 1 over ethereum-1 | expectations recorded
// waiting: 5
// b1's notice: acknowledged | epoch 2 over ethereum-2
// old epoch client retired: true | backlog clients retired by the switch: 0 | waiting: 4
// pruned: 2 | waiting: 2
// pruned: 2 | waiting: 0
// a replaced route client retired for good: true
