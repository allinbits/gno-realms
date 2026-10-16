package impl

import (
	"chain"
	"testing"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func replacedRoute(t *testing.T) *controls.Route {
	reg := controls.NewRegistry()
	rt, err := reg.Enroll("ethereum-1", testutils.TestAddress("collector"), 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := reg.Replace("ethereum-1", "ethereum-4", 0, 1000); err != nil {
		t.Fatal(err)
	}
	return rt
}

// A voucher's first hop is the route key inside, the current client on the
// wire; other hops and native denoms are untouched.
func TestWireTranslation(t *testing.T) {
	rt := replacedRoute(t)
	internal := ics20.NewDenom("0xabc", ics20.NewHop("transfer", "ethereum-1"))
	wire := toWire(internal, rt)
	uassert.Equal(t, "transfer/ethereum-4/0xabc", wire.Path())
	uassert.Equal(t, internal.IBCDenom(), toInternal(wire, rt).IBCDenom())

	deep := ics20.NewDenom("uatom", ics20.NewHop("transfer", "ethereum-1"), ics20.NewHop("transfer", "07-tendermint-0"))
	uassert.Equal(t, "transfer/ethereum-4/transfer/07-tendermint-0/uatom", toWire(deep, rt).Path())

	native := ics20.NewDenom("ugnot")
	uassert.Equal(t, "ugnot", toWire(native, rt).Path())
	uassert.Equal(t, "ugnot", toInternal(native, rt).Path())
	other := ics20.NewDenom("x", ics20.NewHop("transfer", "ethereum-9"))
	uassert.Equal(t, other.Path(), toWire(other, rt).Path())
	uassert.Equal(t, other.Path(), toInternal(other, rt).Path())
}

func TestCheckRecipient(cur realm, t *testing.T) {
	rt := replacedRoute(t)
	rt.Refuse([]string{"0x1d95d544586eacb63b6154e9e45122b32ded11aa"})
	ok := "0x5f67a5398d91087d1b37a8a43436196a7830867f"
	uassert.NotPanics(t, cur, func() { checkRecipient(rt, ok, "") })
	cases := []struct{ receiver, token, want string }{
		{"0x0000000000000000000000000000000000000000", "", "zero address"},
		{"0x0000000000000000000000000000000000000001", "", "reserved"},
		{"0x1D95D544586EACB63B6154E9E45122B32DED11AA", "", "contract of the bridge"},
		{ok, ok, "the token itself"},
		{"5f67a5398d91087d1b37a8a43436196a7830867f", "", "not an Ethereum address"},
		{"g1abc", "", "not an Ethereum address"},
	}
	for _, c := range cases {
		uassert.PanicsContains(t, cur, c.want, func() { checkRecipient(rt, c.receiver, c.token) })
	}
}

func TestBridgeRealms(t *testing.T) {
	for _, p := range bridgeRealms {
		uassert.True(t, isBridgeRealm(chain.PackageAddress(p)), p)
	}
	uassert.False(t, isBridgeRealm(testutils.TestAddress("alice")))
}
