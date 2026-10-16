// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"
	"testing"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/p/nt/testutils/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridge is the route's Ethereum router, ICS20 transfer and IBCAdmin: its
// protected recipients.
const bridge = "0x00000000000000000000000000000000000b0001 0x00000000000000000000000000000000000b0002 0x00000000000000000000000000000000000b0003"

var collector = testutils.TestAddress("collector")

// The staged activation's description, which is also its decision's text,
// spells out every field of every staged denom (ADR pr6375 §7.5: the
// parameters are the record; Codex round 4 #7): changing any one changes it.
func main(cur realm) {
	client := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), client, [][]byte{{}}, "client-0")
	base := []string{"ugnot", "unescrow", "10000", "0", "20", "2", "25000", "40", "10000", "0x0000000000000000000000000000000000c0ffee"}
	describe := func(fields []string) string {
		return ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", client, string(collector), bridge,
			strings.Join(fields, " "), 4000).Description()
	}
	ref := describe(base)
	println(ref)
	changed := []string{"ugnot", "unescrow", "10001", "0", "2500", "3", "25001", "41", "10001", "0x0000000000000000000000000000000000c0fffe"}
	names := []string{"denom", "kind", "capFloor", "supplyCap", "fee", "feeFloor", "sendMax", "sendMin", "refundCap", "remoteToken"}
	for i := 2; i < len(base); i++ {
		if i == 3 {
			continue // an unescrowed denom has no supply cap: covered by a minted one below
		}
		f := append([]string{}, base...)
		f[i] = changed[i]
		println(names[i], "changes the description:", describe(f) != ref)
	}
	mint := []string{"0x457df1a9866af7b6a78eeba9291fc3e58b4d864b", "mint", "4000", "10000", "10", "1", "0", "0", "4000", "-"}
	m := describe(mint)
	mint[3] = "10001"
	println("supplyCap changes the description:", describe(mint) != m)
	other := ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", client, string(collector), bridge,
		strings.Join(base, " "), 4001).Description()
	println("legacyRefundCap changes the description:", other != ref)
	testing.SetRealm(testing.NewUserRealm(ibcgov.Governor()))
	ibcgov.Govern(cross(cur), ibcgov.NewTransferActivateControlsRequest(cross(cur), "gno.land/r/aib/ibc/apps/transfer/impl/v1", client, string(collector), bridge,
		strings.Join(base, " "), 4000))
	d, _ := ibcgov.Decision(ibcgov.LastDecision())
	println("the decision's text is the description:", d.Text == ref)
}

// Output:
// transfer: activate gno.land/r/aib/ibc/apps/transfer/impl/v1 with route ethereum-1 (fee collector g1vdhkcmr9vd6x7ujlta047h6lta047h6lsp3m50; router 0x00000000000000000000000000000000000b0001, ICS20 transfer 0x00000000000000000000000000000000000b0002, IBCAdmin 0x00000000000000000000000000000000000b0003), legacy refund cap 4000 a day, and denoms ugnot kind=unescrow capFloor=10000 supplyCap=0 fee=20 feeFloor=2 sendMax=25000 sendMin=40 refundCap=10000 remoteToken=0x0000000000000000000000000000000000c0ffee
// capFloor changes the description: true
// fee changes the description: true
// feeFloor changes the description: true
// sendMax changes the description: true
// sendMin changes the description: true
// refundCap changes the description: true
// remoteToken changes the description: true
// supplyCap changes the description: true
// legacyRefundCap changes the description: true
// the decision's text is the description: true
