package ibcgov

import (
	"strings"
	"testing"

	ethtesting "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// A decision's router client id is checked against the pairing this chain
// knows: the counterparty the core registered for each Ethereum client.
// This chain's own client of the route, which the router's grammar admits,
// is refused with the id that was meant. The scopes over a bound channel
// are exercised by the z2f filetest (the transfer implementation the
// binding needs imports this realm).
func TestRouterClientPairing(cur realm, t *testing.T) {
	route := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())
	core.RegisterCounterparty(cross(cur), route, [][]byte{{}}, "client-0")
	bare := core.CreateClient(cross(cur), ethtesting.ClientState(), ethtesting.ConsensusState())

	if got := gnoClientHint(route); got != "; "+route+" is this chain's client, paired with client-0" {
		t.Errorf("a paired client: %q", got)
	}
	if got := gnoClientHint(bare); got != "; "+bare+" is this chain's client, with no counterparty registered" {
		t.Errorf("a client with no counterparty: %q", got)
	}
	if got := gnoClientHint("client-0"); got != "" {
		t.Errorf("a router client: %q", got)
	}
	if got := checkRouterClient("", noRouterClient); got != "" {
		t.Errorf("no router client named: %q", got)
	}
	for _, scope := range []int{currentRouterClient, lineageRouterClient, knownRouterClient} {
		if got := checkRouterClient("client-0", scope); got != "the governance channel is not bound" {
			t.Errorf("scope %d unbound: %q", scope, got)
		}
	}

	// Kind 6 op 1 adds the custom id the gno client it tracks is paired with.
	add := func(id, tracks string) string {
		r := revive(func() {
			NewEthClientRequest(cross(cur), 1, id, tracks, "6d61696e", "0x1111111111111111111111111111111111111111", strings.Repeat("ab", 32))
		})
		if r == nil {
			return ""
		}
		if err, ok := r.(error); ok {
			return err.Error()
		}
		return r.(string)
	}
	if got := add("client-0", route); got != "ibcgov: a router client id added by governance is a custom id: 4 to 128 characters of a-z A-Z 0-9 . _ + - # [ ] < >, not starting with client- or channel-: client-0" {
		t.Errorf("the router's own id: %q", got)
	}
	if got := add("gnoland-2", route); got != "ibcgov: the gno client "+route+" is paired with client-0, not gnoland-2" {
		t.Errorf("another id than the pairing's: %q", got)
	}
	if got := add(route, route); got != "ibcgov: the gno client "+route+" is paired with client-0, not "+route {
		t.Errorf("the gno client's own id: %q", got)
	}
	if got := add("gnoland-3", bare); got != "ibcgov: the gno client "+bare+" is paired with no router client yet, not gnoland-3" {
		t.Errorf("no counterparty registered: %q", got)
	}
	if got := add("gnoland-2", "gnoland-2"); got != "ibcgov: the counterparty gnoland-2 is not a gno client" {
		t.Errorf("not a gno client: %q", got)
	}
}
