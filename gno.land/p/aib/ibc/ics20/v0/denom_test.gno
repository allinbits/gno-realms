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

// Ethereum router client ids are hops on an Ethereum route: suffixless and
// up to 128 characters (Codex round 4 #2, class C).
func TestRouterHops(t *testing.T) {
	long := "gnoland." + strings.Repeat("x", 120)
	for _, id := range []string{"gnoland", "gnoland." + strings.Repeat("x", 57), long} {
		d := ics20.ExtractDenomFromPathFunc("transfer/"+id+"/ugnot", ics20.IsHopClientID)
		urequire.Equal(t, 1, len(d.Trace), id)
		urequire.Equal(t, id, d.Trace[0].ClientId)
		urequire.Equal(t, "ugnot", d.Base)
		urequire.NoError(t, d.ValidateBasic(), id)
	}
	// The SDK parser keeps its rule.
	d := ics20.ExtractDenomFromPath("transfer/gnoland/ugnot")
	urequire.Equal(t, 0, len(d.Trace))
	// 129 characters is no router id.
	bad := ics20.ExtractDenomFromPathFunc("transfer/"+long+"x/ugnot", ics20.IsHopClientID)
	urequire.Equal(t, 0, len(bad.Trace))
}
