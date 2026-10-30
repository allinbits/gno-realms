package ics20_test

import (
	"fmt"
	"strings"
	"testing"

	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestDenomsValidate(t *testing.T) {
	testCases := []struct {
		name     string
		denom    ics20.Denom
		expError string
	}{
		{
			"valid trace with client id",
			ics20.NewDenom("uatone",
				ics20.NewHop("transfer", "07-tendermint-0"),
			),
			"",
		},
		{
			"valid multiple trace info",
			ics20.NewDenom("ugnot",
				ics20.NewHop("transfer", "channel-1"),
				ics20.NewHop("transfer", "channel-2"),
			),
			"",
		},
		{
			"empty base denom with trace",
			ics20.NewDenom("", ics20.NewHop("transfer", "channel-1")),
			"base denomination cannot be blank",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {

			err := tc.denom.ValidateBasic()

			if tc.expError == "" {
				urequire.NoError(t, err)
				return
			}
			urequire.ErrorContains(t, err, tc.expError)
		})
	}
}

func TestExtractDenomFromPath(t *testing.T) {
	testCases := []struct {
		name     string
		fullPath string
		expDenom ics20.Denom
	}{
		{
			name:     "empty denom",
			fullPath: "",
			expDenom: ics20.NewDenom(""),
		},
		{
			name:     "base denom no slashes",
			fullPath: "gnot",
			expDenom: ics20.NewDenom("gnot"),
		},
		{
			name:     "base denom with trailing slash",
			fullPath: "gnot/",
			expDenom: ics20.NewDenom("gnot/"),
		},
		{
			name:     "base denom multiple trailing slash",
			fullPath: "foo///bar//baz/gnot/",
			expDenom: ics20.NewDenom("foo///bar//baz/gnot/"),
		},
		{
			name:     "ibc denom one hop",
			fullPath: "transfer/channel-0/gnot",
			expDenom: ics20.NewDenom("gnot", ics20.NewHop("transfer", "channel-0")),
		},
		{
			name:     "ibc denom one hop with client id",
			fullPath: "transfer/07-tendermint-0/gnot",
			expDenom: ics20.NewDenom("gnot", ics20.NewHop("transfer", "07-tendermint-0")),
		},
		{
			name:     "ibc denom one hop trailing slash",
			fullPath: "transfer/channel-0/gnot/",
			expDenom: ics20.NewDenom("gnot/", ics20.NewHop("transfer", "channel-0")),
		},
		{
			name:     "ibc denom one hop multiple slashes",
			fullPath: "transfer/channel-0//at/om/",
			expDenom: ics20.NewDenom("/at/om/", ics20.NewHop("transfer", "channel-0")),
		},
		{
			name:     "ibc denom two hops",
			fullPath: "transfer/channel-0/transfer/channel-60/gnot",
			expDenom: ics20.NewDenom("gnot", ics20.NewHop("transfer", "channel-0"), ics20.NewHop("transfer", "channel-60")),
		},
		{
			name:     "ibc denom two hops trailing slash",
			fullPath: "transfer/channel-0/transfer/channel-60/gnot/",
			expDenom: ics20.NewDenom("gnot/", ics20.NewHop("transfer", "channel-0"), ics20.NewHop("transfer", "channel-60")),
		},
		{
			name:     "empty prefix",
			fullPath: "/ugnot",
			expDenom: ics20.NewDenom("/ugnot"),
		},
		{
			name:     "empty identifiers",
			fullPath: "//ugnot",
			expDenom: ics20.NewDenom("//ugnot"),
		},
		{
			name:     "base denom with single '/'",
			fullPath: "erc20/0x85bcBCd7e79Ec36f4fBBDc54F90C643d921151AA",
			expDenom: ics20.NewDenom("erc20/0x85bcBCd7e79Ec36f4fBBDc54F90C643d921151AA"),
		},
		{
			name:     "trace info and base denom with single '/'",
			fullPath: "transfer/channel-1/erc20/0x85bcBCd7e79Ec36f4fBBDc54F90C643d921151AA",
			expDenom: ics20.NewDenom("erc20/0x85bcBCd7e79Ec36f4fBBDc54F90C643d921151AA", ics20.NewHop("transfer", "channel-1")),
		},
		{
			name:     "single trace identifier",
			fullPath: "transfer/",
			expDenom: ics20.NewDenom("transfer/"),
		},
		{
			name:     "trace info with custom port",
			fullPath: "customtransfer/channel-1/ugnot",
			expDenom: ics20.NewDenom("ugnot", ics20.NewHop("customtransfer", "channel-1")),
		},
		{
			name:     "invalid path (1)",
			fullPath: "channel-1/transfer/ugnot",
			expDenom: ics20.NewDenom("channel-1/transfer/ugnot"),
		},
		{
			name:     "invalid path (2)",
			fullPath: "transfer/channel-1",
			expDenom: ics20.NewDenom("transfer/channel-1"),
		},
		{
			name:     "invalid path (3)",
			fullPath: "transfer/channel-1/transfer/channel-2",
			expDenom: ics20.NewDenom("", ics20.NewHop("transfer", "channel-1"), ics20.NewHop("transfer", "channel-2")),
		},
		{
			name:     "invalid path (4)",
			fullPath: "transfer/channelToA/ugnot",
			expDenom: ics20.NewDenom("transfer/channelToA/ugnot"),
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {

			denom := ics20.ExtractDenomFromPath(tc.fullPath)

			fmt.Println(tc.fullPath, strings.Contains(denom.Base, "/"))

			uassert.Equal(t, tc.expDenom.Base, denom.Base)
			if uassert.Equal(t, len(tc.expDenom.Trace), len(denom.Trace), "trace: unexpected number of hops") {
				for i := range tc.expDenom.Trace {
					uassert.Equal(t, tc.expDenom.Trace[i].PortId, denom.Trace[i].PortId,
						ufmt.Sprintf("unexpected hop #%d portId", i))
					uassert.Equal(t, tc.expDenom.Trace[i].ClientId, denom.Trace[i].ClientId,
						ufmt.Sprintf("unexpected hop #%d channelId", i))
				}
			}
		})
	}
}

// On an Ethereum route the router's own client id for gno.land is a hop,
// suffixless and up to 128 characters (Codex round 4 #2, class C), and so is
// a "client-N" the router generated.
func TestRouterHops(t *testing.T) {
	long := "gnoland." + strings.Repeat("x", 120)
	for _, id := range []string{"gnoland", "gnoland." + strings.Repeat("x", 57), long} {
		d := ics20.ExtractDenomFromPathFunc("transfer/"+id+"/ugnot", ics20.EthereumHop(id))
		urequire.Equal(t, 1, len(d.Trace), id)
		urequire.Equal(t, id, d.Trace[0].ClientId)
		urequire.Equal(t, "ugnot", d.Base)
	}
	d := ics20.ExtractDenomFromPathFunc("transfer/client-7/transfer/07-tendermint-0/uatom", ics20.EthereumHop("gnoland"))
	urequire.Equal(t, 2, len(d.Trace))
	urequire.Equal(t, "client-7", d.Trace[0].ClientId)
	urequire.Equal(t, "07-tendermint-0", d.Trace[1].ClientId)
	urequire.Equal(t, "uatom", d.Base)
	// The SDK parser keeps its rule.
	d = ics20.ExtractDenomFromPath("transfer/gnoland/ugnot")
	urequire.Equal(t, 0, len(d.Trace))
	// 129 characters is no router id, even the route's own.
	bad := ics20.ExtractDenomFromPathFunc("transfer/"+long+"x/ugnot", ics20.EthereumHop(long+"x"))
	urequire.Equal(t, 0, len(bad.Trace))
}

// Another custom router id is no hop on an Ethereum route: an ERC20
// address, "pool" or a bech32 account stays in the base, slashed, where the
// route's no-slash rule refuses it, instead of naming a hop.
func TestRouterHopsRefuseOtherCustomIDs(t *testing.T) {
	hop := ics20.EthereumHop("gnoland")
	for _, c := range []struct{ path, base string }{
		{"transfer/client-0/erc20/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", "erc20/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"},
		{"transfer/client-0/gamm/pool/1", "gamm/pool/1"},
		{"transfer/client-0/factory/cosmos1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/sub", "factory/cosmos1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/sub"},
		{"transfer/osmosis/uosmo", "transfer/osmosis/uosmo"},
	} {
		d := ics20.ExtractDenomFromPathFunc(c.path, hop)
		urequire.Equal(t, c.base, d.Base, c.path)
		data := ics20.NewFungibleTokenPacketData(c.path, "100", "0x5f67a5398d91087d1b37a8a43436196a7830867f", "g1x", "")
		got, err := data.ValidateBasicEthereum("gnoland")
		urequire.NoError(t, err, c.path)
		urequire.Equal(t, c.base, got.Base, c.path)
	}
}

// Hop validation is the SDK's, unchanged from the base (Codex round 11 #4):
// a hop's client id is an ICS24 identifier of at most 64 characters, so a
// 65- or 128-character SDK-shaped client id fails a transfer's validation
// as it did; the router grammar applies only where an Ethereum route
// extracts its own denoms (ExtractDenomFromPathFunc with EthereumHop).
func TestHopValidationIsTheBase(t *testing.T) {
	id := func(n int) string { return strings.Repeat("a", n-2) + "-1" } // SDK-shaped: {type}-{N}
	for _, c := range []struct {
		n  int
		ok bool
	}{{64, true}, {65, false}, {128, false}} {
		data := ics20.NewFungibleTokenPacketData("transfer/"+id(c.n)+"/ucoin", "100", "atone1sender", "g1receiver", "")
		err := data.ValidateBasic()
		if (err == nil) != c.ok {
			t.Fatalf("length %d: %v", c.n, err)
		}
	}
}

// An Ethereum route checks its packet data by the router's grammar alone
// (Codex round 12 #1, #5): hops with ids ending in "-1" of 64, 65 and 128
// characters pass, where the SDK rule takes only the 64-character one, and a
// blank receiver is left to the route's sweep.
func TestValidateBasicEthereum(t *testing.T) {
	for _, n := range []int{64, 65, 128} {
		id := strings.Repeat("a", n-2) + "-1"
		data := ics20.NewFungibleTokenPacketData("transfer/"+id+"/ugnot", "100", "0x5f67a5398d91087d1b37a8a43436196a7830867f", "", "")
		d, err := data.ValidateBasicEthereum("gnoland")
		if err != nil || len(d.Trace) != 1 || d.Trace[0].ClientId != id || d.Base != "ugnot" {
			t.Fatalf("length %d: %v %+v", n, err, d)
		}
		data.Receiver = "g1x"
		if (data.ValidateBasic() == nil) != (n == 64) {
			t.Fatalf("the SDK rule at length %d", n)
		}
	}
	if _, err := ics20.NewFungibleTokenPacketData("transfer/"+strings.Repeat("a", 127)+"-1/ugnot", "100", "0xabc", "x", "").ValidateBasicEthereum("gnoland"); err == nil {
		t.Fatalf("a 129-character id")
	}
}
