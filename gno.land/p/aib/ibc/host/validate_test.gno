package host_test

import (
	"errors"
	"testing"

	"gno.land/p/aib/ibc/host"
	"gno.land/p/nt/urequire"
)

// 195 characters
var longID = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Duis eros neque, ultricies vel ligula ac, convallis porttitor elit. Maecenas tincidunt turpis elit, vel faucibus nisl pellentesque sodales"

type testCase struct {
	msg    string
	id     string
	expErr error
}

func TestClientIdentifierValidator(t *testing.T) {
	testCases := []testCase{
		{"valid lowercase", "lowercaseid", nil},
		{"valid id special chars", "._+-#[]<>._+-#[]<>", nil},
		{"valid id lower and special chars", "lower._+-#[]<>", nil},
		{"numeric id", "1234567890", nil},
		{"uppercase id", "NOTLOWERCASE", nil},
		{"blank id", "               ", errors.New("the ID is blank - contains only spaces")},
		{"id length out of range", "1", errors.New("the ID length is too short")},
		{"id is too long", "this identifier is too long to be used as a valid identifier", errors.New("the ID exceeds the maximum allowed length")},
		{"path-like id", "lower/case/id", errors.New("the ID contains path-like characters, which are invalid for client IDs")},
		{"invalid id", "(clientid)", errors.New("the ID contains invalid characters")},
		{"empty string", "", errors.New("the ID cannot be empty")},
	}

	for _, tc := range testCases {
		err := host.ClientIdentifierValidator(tc.id)
		if tc.expErr == nil {
			urequire.NoError(t, err, tc.msg)
		} else {
			urequire.Error(t, err, tc.msg)
		}
	}
}

func TestPortIdentifierValidator(t *testing.T) {
	testCases := []testCase{
		{"valid lowercase", "transfer", nil},
		{"valid id special chars", "._+-#[]<>._+-#[]<>", nil},
		{"valid id lower and special chars", "lower._+-#[]<>", nil},
		{"numeric id", "1234567890", nil},
		{"uppercase id", "NOTLOWERCASE", nil},
		{"blank id", "               ", errors.New("the ID is blank - contains only spaces")},
		{"id length out of range", "1", errors.New("the ID length is too short")},
		{"id is too long", longID, errors.New("the ID exceeds the maximum allowed length")},
		{"invalid id", "(clientid)", errors.New("the ID contains invalid characters")},
		{"empty string", "", errors.New("the ID cannot be empty")},
		// Port identifiers allow "/" for application identifiers
		{"path-like id allowed for ports", "lower/case/id", nil},
		{"vaas consumer app id", "vaas/consumer", nil},
		{"vaas provider app id", "vaas/provider", nil},
		{"single slash", "a/b", nil},
		{"multiple slashes", "a/b/c/d", nil},
		{"slash only not valid (too short after trim)", "/", errors.New("the ID length is too short")},
	}

	for _, tc := range testCases {
		err := host.PortIdentifierValidator(tc.id)
		if tc.expErr == nil {
			urequire.NoError(t, err, tc.msg)
		} else {
			urequire.Error(t, err, tc.msg)
		}
	}
}

// TestDefaultIdentifierValidator tests shared cases where both client and port
// validators agree on the result.
func TestDefaultIdentifierValidator(t *testing.T) {
	// These cases should produce the same result for both validators.
	testCases := []testCase{
		{"valid lowercase", "lowercaseid", nil},
		{"valid id special chars", "._+-#[]<>._+-#[]<>", nil},
		{"valid id lower and special chars", "lower._+-#[]<>", nil},
		{"numeric id", "1234567890", nil},
		{"uppercase id", "NOTLOWERCASE", nil},
		{"blank id", "               ", errors.New("the ID is blank - contains only spaces")},
		{"invalid id", "(clientid)", errors.New("the ID contains invalid characters")},
		{"empty string", "", errors.New("the ID cannot be empty")},
	}

	for _, tc := range testCases {
		err := host.ClientIdentifierValidator(tc.id)
		err2 := host.PortIdentifierValidator(tc.id)
		if tc.expErr == nil {
			urequire.NoError(t, err, tc.msg)
			urequire.NoError(t, err2, tc.msg)
		} else {
			urequire.Error(t, err, tc.msg)
			urequire.Error(t, err2, tc.msg)
		}
	}
}

// TestPortAllowsSlashButClientDoesNot verifies that "/" is allowed in port IDs
// (for application identifiers like "vaas/consumer") but rejected in client IDs.
func TestPortAllowsSlashButClientDoesNot(t *testing.T) {
	slashIDs := []string{
		"vaas/consumer",
		"vaas/provider",
		"lower/case/id",
		"app/v2/module",
	}

	for _, id := range slashIDs {
		// Port validator should accept "/"
		err := host.PortIdentifierValidator(id)
		urequire.NoError(t, err, "port should accept: "+id)

		// Client validator should reject "/"
		err = host.ClientIdentifierValidator(id)
		urequire.Error(t, err, "client should reject: "+id)
	}
}
