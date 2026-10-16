package types_test

import (
	"testing"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestValidateClientType(t *testing.T) {
	testCases := []struct {
		name       string
		clientType string
		expError   string
	}{
		{"valid", "tendermint", ""},
		{"valid solomachine", "solomachine-v1", ""},
		{"too large", "tenderminttenderminttenderminttenderminttendermintt", "invalid length: 72, must be between 4-64 characters"},
		{"too short", "t", "invalid length: 3, must be between 4-64 characters"},
		{"blank id", "               ", "client type cannot be blank"},
		{"empty id", "", "client type cannot be blank"},
		{"ends with dash", "tendermint-", "not a valid clientID: tendermint--0"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			err := types.ValidateClientType(tc.clientType)

			if tc.expError == "" {
				urequire.NoError(t, err, tc.name)
			} else {
				urequire.ErrorContains(t, err, tc.expError)
			}
		})
	}
}

// Ethereum router client ids follow eureka's rules, not the SDK's (Codex
// review #12).
func TestRouterClientIDs(t *testing.T) {
	for _, tc := range []struct {
		id             string
		custom, router bool
	}{
		{"gnoland", true, true}, // suffixless: a valid custom id, not an SDK one
		{"gnoland-2", true, true},
		{"ab.c_+-#[]<>", true, true},
		{"client-0", false, true}, // the router's own counter
		{"client-42", false, true},
		{"client-", false, false},
		{"client-01", false, false},
		{"client-x", false, false},
		{"channel-1", false, false}, // reserved prefix
		{"abc", false, false},       // too short
		{"gno/land", false, false},  // bad character
		{"", false, false},
	} {
		if types.IsValidCustomClientID(tc.id) != tc.custom || types.IsValidRouterClientID(tc.id) != tc.router {
			t.Errorf("%q: custom %v router %v", tc.id, types.IsValidCustomClientID(tc.id), types.IsValidRouterClientID(tc.id))
		}
	}
	if types.IsValidClientID("gnoland") {
		t.Errorf("gnoland is an SDK client id")
	}
}
