// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"
	"strconv"
	"strings"
	"testing"
	"time"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var collector = testutils.TestAddress("collector")

// vectors are the envelopes of the decisions below, by seq, computed
// independently of this realm: the 14-byte header (version 1, epoch 1, seq,
// kind; big-endian) followed by viem 2.56.3's encodeAbiParameters of the
// kind's tuple with the same values (ADR pr6375 §5.4 table).
var vectors = map[uint64]string{
	1:  "0100000001000000000000000102000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000008636c69656e742d30000000000000000000000000000000000000000000000000",
	2:  "01000000010000000000000002030000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000ab",
	3:  "010000000100000000000000030400000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000005d21dba00000000000000000000000000000000000000000000000000000000174876e800000000000000000000000000000000000000000000000000000000174876e80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002625a000000000000000000000000000000000000000000000000000000000000000008636c69656e742d30000000000000000000000000000000000000000000000000",
	4:  "0100000001000000000000000405000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000001111111111111111111111111111111111111111abababababababababababababababababababababababababababababababab0000000000000000000000000000000000000000000000000000000000000008636c69656e742d30000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000575676e6f74000000000000000000000000000000000000000000000000000000",
	5:  "0100000001000000000000000506000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001400000000000000000000000001111111111111111111111111111111111111111abababababababababababababababababababababababababababababababab0000000000000000000000000000000000000000000000000000000000000009676e6f6c616e642d320000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a657468657265756d2d31000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000046d61696e00000000000000000000000000000000000000000000000000000000",
	6:  "0100000001000000000000000607000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000000ababababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000021cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd00000000000000000000000000000000000000000000000000000000000000",
	7:  "0100000001000000000000000708000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000030000000000000000000000001111111111111111111111111111111111111111",
	8:  "01000000010000000000000008090000000000000000000000001111111111111111111111111111111111111111abababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000",
	9:  "010000000100000000000000090a000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000004d20000000000000000000000000000000000000000000000000000000000000008636c69656e742d300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009676e6f6c616e642d320000000000000000000000000000000000000000000000",
	10: "0100000001000000000000000a0b00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000093a800000000000000000000000000000000000000000000000000000000000000008636c69656e742d30000000000000000000000000000000000000000000000000",
	11: "0100000001000000000000000b01000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000007",
}

const (
	a1   = "0x1111111111111111111111111111111111111111"
	a2   = "0x00000000000000000000000000000000000000ab"
	hash = "abababababababababababababababababababababababababababababababab"
)

// advance moves the block time on by d.
func advance(d time.Duration) {
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(d)
	testing.SetContext(ctx)
}

// govern makes a decision as the governor and returns its number.
func govern(cur realm, req ibcgov.Request) int64 {
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), req)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	return ibcgov.LastDecision()
}

// execute applies a queued decision once its 7 days have passed.
func execute(cur realm, id int64) {
	advance(7*24*time.Hour + time.Second)
	ibcgov.Execute(cross(cur), id)
}

// setupRoute creates an Ethereum client, installs transfer impl/v1 and
// enrolls the client as a route, every step a governor decision.
func setupRoute(cur realm) string {
	clientID := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{}}, "client-0")
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), clientID, string(collector), bridge)))
	advance(7*24*time.Hour + time.Second) // keeps the timeline of the goldens
	return clientID
}

// Every Ethereum-bound kind (ADR pr6375 §5.4): its envelope, bound to the next
// seq of the epoch and dispatched at once, is byte for byte the expected
// encoding. A kind 6 decision with gno.land's two-item merkle prefix fits the
// 1024-byte envelope; a longer envelope is refused when it is built.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	// The gno client approved to carry the epoch over gnoland-2 (kind 10).
	local := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), local, [][]byte{{}}, "gnoland-2")
	// The governance channel rides a route: enroll the client first.
	execute(cur, govern(cur, ibcgov.NewEnrollRouteRequest(cross(cur), client, string(ibcgov.Governor()), "0x1d95d544586eacb63b6154e9e45122b32ded11aa 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003")))
	execute(cur, govern(cur, ibcgov.NewBindGovernanceRequest(cross(cur), client)))

	govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 1, "client-0"))
	govern(cur, ibcgov.NewEthSeatsRequest(cross(cur), "0:"+a1+",4:"+a2))
	govern(cur, ibcgov.NewEthLimitsRequest(cross(cur), "client-0", a1, "25000000000", "100000000000", "100000000000", "0", "40000000"))
	govern(cur, ibcgov.NewEthVoucherRequest(cross(cur), "client-0", "ugnot", a1, hash))
	govern(cur, ibcgov.NewEthClientRequest(cross(cur), 1, "gnoland-2", client, "6d61696e", a1, hash))
	govern(cur, ibcgov.NewEthUpgradeRequest(cross(cur), a1, a2, "0x"+hash, "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"))
	govern(cur, ibcgov.NewEthRoleRequest(cross(cur), true, 3, a1))
	govern(cur, ibcgov.NewEthHandOverRequest(cross(cur), a1, hash))
	govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "client-0", "gnoland-2", 1234, local))
	govern(cur, ibcgov.NewEthRouteSettingsRequest(cross(cur), "client-0", 604800))
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), "1-3,7"))

	for seq := uint64(1); seq <= 11; seq++ {
		got := hex.EncodeToString(ibcgov.DispatchBody(1, seq))
		println("seq", strconv.FormatUint(seq, 10), "matches:", got == vectors[seq], len(got)/2, "bytes")
		if got != vectors[seq] {
			println("  got ", got)
			println("  want", vectors[seq])
		}
	}
	println("last seq:", ibcgov.LastSeq(1))

	govern(cur, ibcgov.NewEthClientRequest(cross(cur), 1, "gnoland-3", client, "6d61696e,2f70762f766d3a676e6f2e6c616e642f722f6169622f6962632f636f72653a", a1, hash))
	println("full gno prefix:", len(ibcgov.DispatchBody(1, 12)), "bytes")
	long := ""
	for i := 0; i < 900; i++ {
		long += "cd"
	}
	println("too long:", revive(func() { govern(cur, ibcgov.NewEthUpgradeRequest(cross(cur), a1, a2, hash, long)) }))
	println("cancel beyond the last seq:", revive(func() { govern(cur, ibcgov.NewEthCancelRequest(cross(cur), "13")) }))
	println("a router id of the router's own:", revive(func() {
		govern(cur, ibcgov.NewEthRouteReplacementRequest(cross(cur), "client-0", "client-9", 1234, local))
	}))
	println("ADMIN_ROLE:", revive(func() { govern(cur, ibcgov.NewEthRoleRequest(cross(cur), true, 0, a1)) }))
	println("three guardian seats:", revive(func() {
		govern(cur, ibcgov.NewEthSeatsRequest(cross(cur), "0:"+a1+",1:"+a1+",2:"+a2))
	}))
	println("unpause object 2 with a client:", revive(func() { govern(cur, ibcgov.NewEthUnpauseRequest(cross(cur), 2, "client-0")) }))
	println("bad address:", revive(func() { govern(cur, ibcgov.NewEthVoucherRequest(cross(cur), "client-0", "ugnot", "0x1234", hash)) }))
	ranges := func(n int) string {
		var r []string
		for i := 0; i < n; i++ {
			r = append(r, "1-2")
		}
		return strings.Join(r, ",")
	}
	println("fifteen cancel ranges:", revive(func() { govern(cur, ibcgov.NewEthCancelRequest(cross(cur), ranges(15))) }))
	println("last seq after the refusals:", ibcgov.LastSeq(1))
	govern(cur, ibcgov.NewEthCancelRequest(cross(cur), ranges(14)))
	println("fourteen cancel ranges:", len(ibcgov.DispatchBody(1, ibcgov.LastSeq(1))), "bytes")

	// Kind 5 takes a gno.land denom as the transfer app sends it: a GRC20
	// alias of a hyphenated realm path is one; a realm-issued coin and a
	// path segment gno refuses are not.
	govern(cur, ibcgov.NewEthVoucherRequest(cross(cur), "client-0", "gno.land:r:my-org:token.TKN", a1, hash))
	println("hyphenated realm path dispatched:", len(ibcgov.DispatchBody(1, ibcgov.LastSeq(1))), "bytes")
	println("realm-issued coin:", revive(func() {
		govern(cur, ibcgov.NewEthVoucherRequest(cross(cur), "client-0", "/gno.land/r/my-org/token:coin", a1, hash))
	}))
	println("doubled hyphen:", revive(func() {
		govern(cur, ibcgov.NewEthVoucherRequest(cross(cur), "client-0", "gno.land:r:my--org:token", a1, hash))
	}))
}

// Output:
// seq 1 matches: true 142 bytes
// seq 2 matches: true 206 bytes
// seq 3 matches: true 302 bytes
// seq 4 matches: true 270 bytes
// seq 5 matches: true 462 bytes
// seq 6 matches: true 238 bytes
// seq 7 matches: true 110 bytes
// seq 8 matches: true 142 bytes
// seq 9 matches: true 238 bytes
// seq 10 matches: true 142 bytes
// seq 11 matches: true 206 bytes
// last seq: 11
// full gno prefix: 558 bytes
// too long: ibcgov: the envelope would be 1102 bytes, above 1024
// cancel beyond the last seq: ibcgov: not a range of dispatched numbers (1-12): 13
// a router id of the router's own: ibcgov: a router client id added by governance is a custom id: 4 to 128 characters of a-z A-Z 0-9 . _ + - # [ ] < >, not starting with client- or channel-: client-9
// ADMIN_ROLE: ibcgov: kind 8 never names ADMIN_ROLE or PUBLIC_ROLE
// three guardian seats: ibcgov: a decision changes at most two guardian seats
// unpause object 2 with a client: ibcgov: object 2 (IBCAdmin) names no client
// bad address: ibcgov: not an Ethereum address: want 0x and 40 hex digits
// fifteen cancel ranges: ibcgov: name 1 to 14 ranges: no more fit the 1024-byte envelope
// last seq after the refusals: 12
// fourteen cancel ranges: 974 bytes
// hyphenated realm path dispatched: 270 bytes
// realm-issued coin: ibcgov: not a gno.land denom the transfer app sends: /gno.land/r/my-org/token:coin
// doubled hyphen: ibcgov: not a gno.land denom the transfer app sends: gno.land:r:my--org:token
