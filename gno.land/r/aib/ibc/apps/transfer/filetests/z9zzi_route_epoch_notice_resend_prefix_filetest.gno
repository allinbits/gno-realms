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
		case string(ack) == string(types.CommitAcknowledgement(types.Acknowledgement{AppAcknowledgements: [][]byte{govAck(ibcgov.Epoch(), 1)}})):
			out = "status 1 (switched)"
		case string(ack) == string(types.CommitAcknowledgement(types.Acknowledgement{AppAcknowledgements: [][]byte{govAck(ibcgov.Epoch(), 3)}})):
			out = "status 3 (duplicate)"
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

// govAck is ibcgov's app acknowledgement of a notice: epoch u32 ‖ seq u64
// (0) ‖ status u8 ‖ redispatch u8 (0).
func govAck(e uint32, status uint8) []byte {
	b := make([]byte, 14)
	b[0], b[1], b[2], b[3] = byte(e>>24), byte(e>>16), byte(e>>8), byte(e)
	b[12] = status
	return b
}

// Resent notices and catching up in prefixes (design review r4 #1):
// IBCAdmin may resend the notice of any recorded epoch at any time, even
// after it was acknowledged. A resend of the epoch already switched to is
// answered as a duplicate (status 3); one of a competing transition, or of
// an epoch the switch passed over a client retired for governance, is
// refused, the epoch unchanged. In a chain client-0 → a1 → … → a6, the
// notice of epoch 7 is recorded as proven first; applying the prefix to
// epoch 4 keeps every transition the rest needs, and epoch 7's notice then
// applies from there.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	a1 := client(cur, "ethereum-2", "gnoland-a1",
		noticePacket(1, "gnoland-a1", "ethereum-2", 2, "gnoland-a1"),
		noticePacket(2, "gnoland-a1", "ethereum-2", 2, "gnoland-a1"),
		noticePacket(3, "gnoland-a1", "ethereum-2", 2, "gnoland-a1"))
	client(cur, "ethereum-3", "gnoland-a2")
	a3 := client(cur, "ethereum-4", "gnoland-a3",
		noticePacket(1, "gnoland-a3", "ethereum-4", 4, "gnoland-a3"),
		noticePacket(2, "gnoland-a3", "ethereum-4", 4, "gnoland-a3"))
	client(cur, "ethereum-5", "gnoland-a4")
	client(cur, "ethereum-6", "gnoland-a5")
	a6 := client(cur, "ethereum-7", "gnoland-a6", noticePacket(1, "gnoland-a6", "ethereum-7", 7, "gnoland-a6"))
	d := client(cur, "ethereum-8", "gnoland-d", noticePacket(1, "gnoland-d", "ethereum-8", 2, "gnoland-d"))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	prev := "client-0"
	for i := 1; i <= 6; i++ {
		r := "gnoland-a" + strconv.Itoa(i)
		kind10(cur, prev, r, 1, "ethereum-"+strconv.Itoa(i+1))
		prev = r
	}
	kind10(cur, "client-0", "gnoland-d", 1, "ethereum-8") // a competing kind 10
	expectAll(cur)

	println("a1's notice:", deliver(cur, a1, 0), "|", epochNow())
	println("a1's notice resent:", deliver(cur, a1, 1), "|", epochNow())
	println("d's competing notice:", deliver(cur, d, 0), "|", epochNow())
	println("a6's notice, 5 steps on:", deliver(cur, a6, 0), "|", epochNow())
	println("a3's notice, 2 steps on:", deliver(cur, a3, 0), "|", epochNow())
	ibcgov.ApplyEpochNotice(cross(cur), 4, "ethereum-4", "gnoland-a2/ethereum-3,gnoland-a3/ethereum-4")
	println("prefix applied:", epochNow())
	println("a3's notice resent:", deliver(cur, a3, 1), "|", epochNow())
	ibcgov.ApplyEpochNotice(cross(cur), 7, "ethereum-7", "gnoland-a4/ethereum-5,gnoland-a5/ethereum-6,gnoland-a6/ethereum-7")
	println("the rest applied:", epochNow())
	println("a1's retired for governance:", core.IsClientRetiredFor("ethereum-2", ibcgov.GovPort))
	println("a1's notice resent again:", revive(func() { deliver(cur, a1, 2) }), "|", epochNow())
}

// Output:
// a1's notice: status 1 (switched) | epoch 2 over ethereum-2
// a1's notice resent: status 3 (duplicate) | epoch 2 over ethereum-2
// d's competing notice: error acknowledgement | epoch 2 over ethereum-2
// a6's notice, 5 steps on: error acknowledgement | epoch 2 over ethereum-2
// a3's notice, 2 steps on: error acknowledgement | epoch 2 over ethereum-2
// prefix applied: epoch 4 over ethereum-4
// a3's notice resent: status 3 (duplicate) | epoch 4 over ethereum-4
// the rest applied: epoch 7 over ethereum-7
// a1's retired for governance: true
// a1's notice resent again: client ethereum-2 is retired for port gov | epoch 7 over ethereum-7
