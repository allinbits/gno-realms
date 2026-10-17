// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	implv1 "gno.land/r/aib/ibc/core/impl/v1"
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

// Expected transitions (ADR pr6375 §7.12; Codex rounds 31 #3, 32 #1). Each
// dispatched kind 10 makes its transition expected here, in router client
// ids, never overwritten; a recovery's is recorded by a decision. Ethereum
// raises its epoch by one per kind 10 or recovery it executes and sends a
// notice over each step's new client, accepted for epoch current + k only
// over a client reached through exactly k expected transitions:
//   - A→B and B→C both execute here before any notice: B stays open for
//     governance, B's notice moves the epoch to 2, then C's to 3; C's notice
//     for epoch 2 (the wrong k) is refused;
//   - competing kind 10s C→D and C→F, gno.land's C→F replacement cancelled:
//     D's notice is accepted all the same;
//   - an emergency recovery D→G, expected by decision: G's notice accepted;
//   - G→H then H→E, H frozen before its notice: E's notice, two steps on,
//     moves the epoch past H; a notice one step too far is refused.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	b := client(cur, "ethereum-2", "gnoland-b", noticePacket(1, "gnoland-b", "ethereum-2", 2, "gnoland-b"))
	c := client(cur, "ethereum-3", "gnoland-c",
		noticePacket(1, "gnoland-c", "ethereum-3", 2, "gnoland-c"), // the wrong step
		noticePacket(2, "gnoland-c", "ethereum-3", 3, "gnoland-c"))
	d := client(cur, "ethereum-4", "gnoland-d", noticePacket(1, "gnoland-d", "ethereum-4", 4, "gnoland-d"))
	client(cur, "ethereum-5", "gnoland-f")
	g := client(cur, "ethereum-6", "gnoland-g", noticePacket(1, "gnoland-g", "ethereum-6", 5, "gnoland-g"))
	h := client(cur, "ethereum-7", "gnoland-h", noticePacket(1, "gnoland-h", "ethereum-7", 6, "gnoland-h"))
	e := healthyClient(cur, "ethereum-8", "gnoland-e",
		noticePacket(1, "gnoland-e", "ethereum-8", 8, "gnoland-e"), // one step too far
		noticePacket(2, "gnoland-e", "ethereum-8", 7, "gnoland-e"))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))

	// A→B and B→C: both kind 10s dispatched, both replacements executed here
	// before any notice.
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "client-0", "gnoland-b", 1, "ethereum-2"))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "gnoland-b", "gnoland-c", 2, "ethereum-3"))
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", "ethereum-2", 0)))
	execute(cur, govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", "ethereum-3", 0)))
	println(epochNow(), "| route client", controlsView().Client("ethereum-1"))
	for _, x := range []string{"ethereum-1", "ethereum-2"} {
		println(x, "retired for transfers:", core.IsClientRetiredFor(x, "transfer"), "for governance:", core.IsClientRetiredFor(x, ibcgov.GovPort))
	}
	println("c's notice for epoch 2:", deliver(cur, c, 0), "|", epochNow())
	println("b's notice:", deliver(cur, b, 0), "|", epochNow(), "| a retired for good:", core.IsClientRetired("ethereum-1"))
	println("c's notice:", deliver(cur, c, 1), "|", epochNow(), "| b retired for good:", core.IsClientRetired("ethereum-2"))

	// Competing kind 10s from C; gno.land's replacement by F is cancelled,
	// by D executed. D's notice is accepted: the expectation of F stays,
	// harmless.
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "gnoland-c", "gnoland-d", 3, "ethereum-4"))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "gnoland-c", "gnoland-f", 3, "ethereum-5"))
	toF := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", "ethereum-5", 0))
	toD := govern(cur, ibcgov.NewReplaceRouteRequest(cross(cur), "ethereum-1", "ethereum-4", 0))
	govern(cur, ibcgov.NewCancelRequest(cross(cur), toF))
	execute(cur, toD)
	println("replace by f:", decided(toF), "| by d:", decided(toD))
	println("d's notice:", deliver(cur, d, 0), "|", epochNow(), "| c retired for good:", core.IsClientRetired("ethereum-3"))

	// Ethereum's emergency recovery moves D's route to G: expected by a
	// decision here, its notice is accepted.
	println("expect the recovery:", decided(govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "gnoland-d", "gnoland-g", "ethereum-6"))))
	println("g's notice:", deliver(cur, g, 0), "|", epochNow())

	// G→H then H→E; H freezes before its notice is relayed.
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "gnoland-g", "gnoland-h", 4, "ethereum-7"))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "gnoland-h", "gnoland-e", 5, "ethereum-8"))
	testing.SetRealm(testing.NewCodeRealm(freezeImpl))
	core.RegisterImpl(cross(cur), func(s core.Store) core.Logic {
		return implv1.NewWithConversions(s, "v1-freeze", []string{ethereum.Version}, []string{ethtesting.FreezingVersion},
			[]func(*ethereum.Retired) lightclient.Interface{ethtesting.ToFreezingVerifier})
	}, "v1-freeze", []string{"v0", "v1"})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), freezeImpl)))
	execute(cur, govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), "ethereum-7", ethtesting.FreezingVersion)))
	setTime(time.Unix(int64(ethtesting.ClientState().GenesisTime)+5000, 0))
	println("h:", core.ClientStatus("ethereum-7"), "| e:", core.ClientStatus("ethereum-8"), "|", epochNow())
	// H's notice can no longer be relayed: the core refuses a packet on a
	// Frozen client.
	_ = h
	println("e's notice one step too far:", deliver(cur, e, 0), "|", epochNow())
	println("e's notice:", deliver(cur, e, 1), "|", epochNow())
}

// Output:
// epoch 1 over ethereum-1 | route client ethereum-3
// ethereum-1 retired for transfers: true for governance: false
// ethereum-2 retired for transfers: true for governance: false
// c's notice for epoch 2: error acknowledgement | epoch 1 over ethereum-1
// b's notice: acknowledged | epoch 2 over ethereum-2 | a retired for good: true
// c's notice: acknowledged | epoch 3 over ethereum-3 | b retired for good: true
// replace by f: cancelled - queued 7 days | by d: applied - replace: client ethereum-3 retired for transfers, meters emptied; governance epoch 3 stays over ethereum-3 until IBCAdmin's epoch notices arrive
// d's notice: acknowledged | epoch 4 over ethereum-4 | c retired for good: true
// expect the recovery: applied - expect the governance epoch to move from gnoland-d to gnoland-g over ethereum-6
// g's notice: acknowledged | epoch 5 over ethereum-6
// h: Frozen | e: Active | epoch 5 over ethereum-6
// e's notice one step too far: error acknowledgement | epoch 5 over ethereum-6
// e's notice: acknowledged | epoch 7 over ethereum-8
