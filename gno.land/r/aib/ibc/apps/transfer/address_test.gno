package transfer

import (
	"strings"
	"testing"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/uassert/v0"
)

const testAddr = "g1wfjkxetfwejhyh6lta047h6lta047h6llm82yl"

func TestCanonicalAddress(t *testing.T) {
	testCases := []struct {
		name     string
		input    string
		expected address
		ok       bool
	}{
		{"lowercase", testAddr, testAddr, true},
		{"uppercase", strings.ToUpper(testAddr), testAddr, true},
		{"mixed case", "G" + testAddr[1:], "", false},
		{"bad checksum", testAddr[:len(testAddr)-1] + "q", "", false},
		{"other prefix", "cosmos1wfjkxetfwejhyh6lta047h6lta047h6lv8mf9m", "", false},
		{"not bech32", "atone1notagnoaddress", "", false},
		{"empty", "", "", false},
		// A valid bech32 string with the g prefix but 32 bytes of data.
		{"wrong length", "g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqemfmay", "", false},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := CanonicalAddress(tc.input)
			uassert.Equal(t, tc.ok, ok)
			uassert.Equal(t, string(tc.expected), string(got))
		})
	}
}

func TestIsBlockedAnySpelling(cur realm, t *testing.T) {
	blocked = bptree.NewBPTree32()
	defer func() { blocked = bptree.NewBPTree32() }()
	blocked.Set(testAddr, true)

	uassert.True(t, IsBlocked(testAddr))
	uassert.True(t, IsBlocked(address(strings.ToUpper(testAddr))))
	uassert.False(t, IsBlocked("atone1notagnoaddress"))
	uassert.PanicsWithMessage(t, cur, "invalid address: atone1notagnoaddress", func() {
		mustCanonicalAddress("atone1notagnoaddress")
	})
	uassert.Equal(t, testAddr, string(mustCanonicalAddress(address(strings.ToUpper(testAddr)))))
}
