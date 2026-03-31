package transfer

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
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
			"gno.land%2Fr%2Fdemo%2Ffoo",
		},
		{
			"path with slug",
			"gno.land/r/demo/foo.FOO",
			"gno.land%2Fr%2Fdemo%2Ffoo.FOO",
		},
		{
			"slug with colon",
			"gno.land/r/demo/foo.A:B",
			"gno.land%2Fr%2Fdemo%2Ffoo.A:B",
		},
		{
			"slug with multiple colons",
			"gno.land/r/demo/foo.A:B:C",
			"gno.land%2Fr%2Fdemo%2Ffoo.A:B:C",
		},
		{
			"slug with percent sign",
			"gno.land/r/demo/foo.A%B",
			"gno.land%2Fr%2Fdemo%2Ffoo.A%25B",
		},
		{
			"slug with literal %2F",
			"gno.land/r/demo/foo.A%2FB",
			"gno.land%2Fr%2Fdemo%2Ffoo.A%252FB",
		},
		{
			"slug with slash",
			"gno.land/r/demo/foo.A/B",
			"gno.land%2Fr%2Fdemo%2Ffoo.A%2FB",
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			alias := GRC20Alias(tc.key)
			uassert.Equal(t, tc.expAlias, alias)

			got, err := resolveGRC20Alias(alias)
			urequire.NoError(t, err)
			uassert.Equal(t, tc.key, got)
		})
	}
}

func TestisGRC20Alias(t *testing.T) {
	testCases := []struct {
		name   string
		denom  string
		expect bool
	}{
		{"grc20 alias", "gno.land%2Fr%2Fdemo%2Ffoo.FOO", true},
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
