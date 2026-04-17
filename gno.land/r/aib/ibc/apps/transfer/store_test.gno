package transfer

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestGRC20AliasRoundTrip(t *testing.T) {
	testCases := []struct {
		name     string
		key      string
		expAlias string
	}{
		{
			"simple path without slug",
			"gno.land/r/demo/foo",
			"gno.land:r:demo:foo",
		},
		{
			"path with slug",
			"gno.land/r/demo/foo.FOO",
			"gno.land:r:demo:foo.FOO",
		},
		{
			"path with alphanumeric slug",
			"gno.land/r/demo/foo.Bar123",
			"gno.land:r:demo:foo.Bar123",
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			alias := GRC20Alias(tc.key)
			uassert.Equal(t, tc.expAlias, alias)

			got := resolveGRC20Alias(alias)
			uassert.Equal(t, tc.key, got)
		})
	}
}

func TestIsGRC20Alias(t *testing.T) {
	testCases := []struct {
		name   string
		denom  string
		expect bool
	}{
		{"grc20 alias", "gno.land:r:demo:foo.FOO", true},
		{"native denom", "ugnot", false},
		{"ibc denom", "ibc/ABC123", false},
		{"gno path not aliased", "gno.land/r/demo/foo", false},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			uassert.Equal(t, tc.expect, isGRC20Alias(tc.denom))
		})
	}
}
