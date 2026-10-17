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
				out = "aborted: " + r.(error).Error()
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

// The governance epoch moves in two phases (ADR pr6375 §7.12, design review
// #1). A route replacement retires the old client for transfers only: the
// epoch stays over it, so decisions in flight, the kind 10 among them, can
// still be re-sent there. IBCAdmin's epoch notice, proven through the new
// client, moves the epoch, whether it arrives after gno.land's replacement
// executes or before; a notice over a client no recorded replacement names,
// for another epoch, or naming another client, is refused (an error
// acknowledgement), and the notice of the epoch switched to already is
// acknowledged again.
func main(cur realm) {
	route := client(cur, "ethereum-1", "client-0")
	b := client(cur, "ethereum-2", "client-1",
		noticePacket(1, "client-1", "ethereum-2", 2, "client-1"), // too early
		noticePacket(2, "client-1", "ethereum-2", 3, "client-1"), // the wrong epoch
		noticePacket(3, "client-1", "ethereum-2", 2, "client-9"), // names another client
		noticePacket(4, "client-1", "ethereum-2", 2, "client-1"), // the notice
		noticePacket(5, "client-1", "ethereum-2", 2, "client-1")) // re-sent
	x := client(cur, "ethereum-3", "client-7", noticePacket(1, "client-7", "ethereum-3", 2, "client-7"))
	c := client(cur, "ethereum-4", "client-2", noticePacket(1, "client-2", "ethereum-4", 3, "client-2"))
	_ = route
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	println(epochNow())

	// A notice before any replacement names its client: refused.
	println("notice over b before its replacement is recorded:", deliver(cur, b, 0), "|", epochNow())

	// gno.land's replacement executes first: the epoch stays over the old
	// client, which still carries governance packets, not transfers.
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", "ethereum-2", 0)))
	println(epochNow(), "| old retired for transfers:", core.IsClientRetiredFor("ethereum-1", "transfer"),
		"for governance:", core.IsClientRetiredFor("ethereum-1", ibcgov.GovPort))
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), "client-0", 0))
	println("a decision after the replacement:", decided(ibcgov.LastDecision()))

	println("notice over x (no replacement):", deliver(cur, x, 0), "|", epochNow())
	println("notice of epoch 3:", deliver(cur, b, 1), "|", epochNow())
	println("notice naming another client:", deliver(cur, b, 2), "|", epochNow())
	println("the notice:", deliver(cur, b, 3), "|", epochNow())
	println("old client retired for good:", core.IsClientRetired("ethereum-1"))
	println("re-sent:", deliver(cur, b, 4), "|", epochNow())

	// The next replacement's notice arrives before gno.land's replacement
	// executes: the epoch moves, the old client is retired for governance
	// and keeps the route until the replacement executes.
	replace := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", "ethereum-4", 0))
	println("notice over c before its replacement executes:", deliver(cur, c, 0), "|", epochNow())
	println("b retired for governance:", core.IsClientRetiredFor("ethereum-2", ibcgov.GovPort), "for transfers:", core.IsClientRetiredFor("ethereum-2", "transfer"))
	execute(cur, replace)
	println("replacement:", decided(replace))
	println("b retired for good:", core.IsClientRetired("ethereum-2"), "|", epochNow())
}

// Output:
// epoch 1 over ethereum-1
// notice over b before its replacement is recorded: error acknowledgement | epoch 1 over ethereum-1
// epoch 1 over ethereum-1 | old retired for transfers: true for governance: false
// a decision after the replacement: applied - dispatched as epoch 1 seq 1
// notice over x (no replacement): error acknowledgement | epoch 1 over ethereum-1
// notice of epoch 3: error acknowledgement | epoch 1 over ethereum-1
// notice naming another client: error acknowledgement | epoch 1 over ethereum-1
// the notice: acknowledged | epoch 2 over ethereum-2
// old client retired for good: true
// re-sent: acknowledged | epoch 2 over ethereum-2
// notice over c before its replacement executes: acknowledged | epoch 3 over ethereum-4
// b retired for governance: true for transfers: false
// replacement: applied - replace: client ethereum-2 retired, meters emptied
// b retired for good: true | epoch 3 over ethereum-4
