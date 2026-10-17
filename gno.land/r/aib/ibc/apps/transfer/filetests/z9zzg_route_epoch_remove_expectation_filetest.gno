// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	implv1 "gno.land/r/aib/ibc/core/impl/v1"
	"gno.land/r/aib/ibc/ibcgov"
)

const freezeImpl = "gno.land/r/aib/ibc/core/impl/v1freeze"

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

// A governed removal of an active expectation (design review r2 #2, a
// deliberate addition): four recovery expectations from the epoch client's
// router counterparty became active, then Ethereum's recoveries were
// cancelled. A fifth expectation is refused, the cap full; the dead
// transitions are removed at once (a tightening), except one a notice
// recorded as proven may still need. Once that notice's client no longer
// vouches for it (a verifier replacement: a new trust generation), it pins
// nothing (design review r3 #4): r1 is removed too, and its place alone
// takes the fifth, whose notice moves the epoch.
func main(cur realm) {
	client(cur, "ethereum-1", "client-0")
	for i := 1; i <= 4; i++ {
		client(cur, "ethereum-"+strconv.Itoa(i+1), "gnoland-r"+strconv.Itoa(i))
	}
	r5 := client(cur, "ethereum-6", "gnoland-r5", noticePacket(1, "gnoland-r5", "ethereum-6", 2, "gnoland-r5"))
	s1 := client(cur, "ethereum-7", "gnoland-s1", noticePacket(1, "gnoland-s1", "ethereum-7", 3, "gnoland-s1"))
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), "ethereum-1", string(collector), bridge)))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), "ethereum-1")))
	var ids []int64
	for i := 1; i <= 4; i++ {
		ids = append(ids, govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-r"+strconv.Itoa(i), "ethereum-"+strconv.Itoa(i+1))))
	}
	ids = append(ids, govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "gnoland-r1", "gnoland-s1", "ethereum-7")))
	advance(7*24*time.Hour + time.Second)
	for _, id := range ids {
		ibcgov.Execute(cross(cur), id)
	}
	// s1's notice, two steps on, is recorded as proven.
	println("s1's notice:", deliver(cur, s1, 0), "|", epochNow())
	println("a fifth expectation:", revive(func() {
		govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-r5", "ethereum-6"))
	}))
	println("remove r1 (s1's proven notice may need it):", revive(func() {
		govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "client-0", "gnoland-r1", "ethereum-2"))
	}))
	// s1's verifier is replaced: its trust generation advances, and the
	// notice proven under the last one can no longer be applied.
	testing.SetRealm(testing.NewCodeRealm(freezeImpl))
	core.RegisterImpl(cross(cur), func(s core.Store) core.Logic {
		return implv1.NewWithConversions(s, "v1-next", []string{ethereum.Version}, []string{ethtesting.NextVersion},
			[]func(*ethereum.Retired) lightclient.Interface{ethtesting.ToNextVerifier})
	}, "v1-next", []string{"v0", "v1"})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	execute(cur, govern(cur, ibcgov.NewCoreUpdateImplRequest(cross(cur), freezeImpl)))
	execute(cur, govern(cur, ibcgov.NewReplaceVerifierRequest(cross(cur), "ethereum-7", ethtesting.NextVersion)))
	id := govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "client-0", "gnoland-r1", "ethereum-2"))
	println("remove r1 (s1's notice void):", decided(id))
	println("remove r1 again:", revive(func() {
		govern(cur, ibcgov.NewRemoveExpectationRequest(cross(cur), "client-0", "gnoland-r1", "ethereum-2"))
	}))
	fifth := govern(cur, ibcgov.NewExpectRecoveryRequest(cross(cur), "client-0", "gnoland-r5", "ethereum-6"))
	execute(cur, fifth)
	println("the fifth:", decided(fifth))
	println("r5's notice:", deliver(cur, r5, 0), "|", epochNow())
}

// Output:
// s1's notice: error acknowledgement | epoch 1 over ethereum-1
// a fifth expectation: ibcgov: router client client-0 has 4 expected successors already, intents included
// remove r1 (s1's proven notice may need it): ibcgov: a notice proven over ethereum-7 may need the transition: apply it or let it lapse first
// remove r1 (s1's notice void): applied - no longer expect the governance epoch to move from client-0 to gnoland-r1 over ethereum-2
// remove r1 again: ibcgov: no active expected transition from client-0 to gnoland-r1 over ethereum-2
// the fifth: applied - expect the governance epoch to move from client-0 to gnoland-r5 over ethereum-6
// r5's notice: acknowledged | epoch 2 over ethereum-6
