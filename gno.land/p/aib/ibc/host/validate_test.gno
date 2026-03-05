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

func TestDefaultIdentifierValidator(t *testing.T) {
	testCases := []testCase{
		{"valid lowercase", "lowercaseid", nil},
		{"valid id special chars", "._+-#[]<>._+-#[]<>", nil},
		{"valid id lower and special chars", "lower._+-#[]<>", nil},
		{"numeric id", "1234567890", nil},
		{"uppercase id", "NOTLOWERCASE", nil},
		{"numeric id", "1234567890", nil},
		{"blank id", "               ", errors.New("the ID is blank - contains only spaces")},
		{"id length out of range", "1", errors.New("the ID length is too short")},
		{"id is too long", "this identifier is too long to be used as a valid identifier", errors.New("the ID exceeds the maximum allowed length")},
		{"path-like id", "lower/case/id", errors.New("the ID contains path-like characters, which are invalid for an ID")},
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

func TestPortIdentifierValidator(t *testing.T) {
	testCases := []testCase{
		{"valid lowercase", "transfer", nil},
		{"valid id special chars", "._+-#[]<>._+-#[]<>", nil},
		{"valid id lower and special chars", "lower._+-#[]<>", nil},
		{"numeric id", "1234567890", nil},
		{"uppercase id", "NOTLOWERCASE", nil},
		{"numeric id", "1234567890", nil},
		{"blank id", "               ", errors.New("the ID is blank - contains only spaces")},
		{"id length out of range", "1", errors.New("the ID length is too short")},
		{"id is too long", longID, errors.New("the ID exceeds the maximum allowed length")},
		{"path-like id", "lower/case/id", errors.New("the ID contains path-like characters, which are invalid for an ID")},
		{"invalid id", "(clientid)", errors.New("the ID contains invalid characters")},
		{"empty string", "", errors.New("the ID cannot be empty")},
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
