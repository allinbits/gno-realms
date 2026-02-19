package host

import (
	"errors"
	"regexp"
	"strings"

	"gno.land/p/nt/ufmt"
)

// IsValidPortID defines regular expression to check if the string consist of
// characters in one of the following categories only:
// - Alphanumeric
// - `.`, `_`, `+`, `-`, `#`, `/`
// - `[`, `]`, `<`, `>`
// Unlike IsValidID, this also allows "/" so that hierarchical application
// identifiers (e.g. "vaas/provider", "vaas/consumer") are accepted.
var IsValidPortID = regexp.MustCompile(`^[a-zA-Z0-9\.\_\+\-\#\[\]\<\>\/]+$`).MatchString

// DefaultMaxCharacterLength defines the default maximum character length used
// in validation of identifiers including the client, connection, port and
// channel identifiers.
//
// NOTE: this restriction is specific to this golang implementation of IBC. If
// your use case demands a higher limit, please open an issue and we will consider
// adjusting this restriction.
const DefaultMaxCharacterLength = 64

// DefaultMaxPortCharacterLength defines the default maximum character length used
// in validation of port identifiers.
var DefaultMaxPortCharacterLength = 128

// IsValidID defines regular expression to check if the string consist of
// characters in one of the following categories only:
// - Alphanumeric
// - `.`, `_`, `+`, `-`, `#`
// - `[`, `]`, `<`, `>`
var IsValidID = regexp.MustCompile(`^[a-zA-Z0-9\.\_\+\-\#\[\]\<\>]+$`).MatchString

// ICS 024 Identifier and Path Validation Implementation
//
// This file defines ValidateFn to validate identifier and path strings
// The spec for ICS 024 can be located here:
// https://github.com/cosmos/ibc/tree/master/spec/core/ics-024-host-requirements

// ValidateFn function type to validate path and identifier bytestrings
type ValidateFn func(string) error

func defaultIdentifierValidator(id string, minLength, maxLength int) error {
	if strings.TrimSpace(id) == "" {
		return errors.New("identifier cannot be blank")
	}
	// valid id MUST NOT contain "/" separator
	if strings.Contains(id, "/") {
		return ufmt.Errorf("identifier %s cannot contain separator '/'", id)
	}
	// valid id must fit the length requirements
	if len(id) < minLength || len(id) > maxLength {
		return ufmt.Errorf("identifier %s has invalid length: %d, must be between %d-%d characters", id, len(id), minLength, maxLength)
	}
	// valid id must contain only alphanumeric characters and some allowed symbols.
	if !IsValidID(id) {
		return ufmt.Errorf(
			"identifier %s must contain only alphanumeric or the following characters: '.', '_', '+', '-', '#', '[', ']', '<', '>'",
			id,
		)
	}
	return nil
}

// ClientIdentifierValidator is the default validator function for Client identifiers.
// A valid Identifier must be between 4-64 characters and only contain alphanumeric and some allowed
// special characters (see IsValidID).
func ClientIdentifierValidator(id string) error {
	err := defaultIdentifierValidator(id, 4, DefaultMaxCharacterLength)
	if err != nil {
		return ufmt.Errorf("validate client identifier: %v", err)
	}
	return nil
}

// PortIdentifierValidator is the validator function for Port identifiers.
// A valid port identifier must be between 2-128 characters and only contain
// alphanumeric and some allowed special characters (see IsValidPortID).
// Unlike other identifiers, port identifiers also allow "/" so that
// hierarchical application identifiers work (e.g. "vaas/consumer").
func PortIdentifierValidator(id string) error {
	if strings.TrimSpace(id) == "" {
		return ufmt.Errorf("validate port identifier: identifier cannot be blank")
	}
	if len(id) < 2 || len(id) > DefaultMaxPortCharacterLength {
		return ufmt.Errorf("validate port identifier: identifier %s has invalid length: %d, must be between %d-%d characters", id, len(id), 2, DefaultMaxPortCharacterLength)
	}
	if !IsValidPortID(id) {
		return ufmt.Errorf(
			"validate port identifier: identifier %s must contain only alphanumeric or the following characters: '.', '_', '+', '-', '#', '/', '[', ']', '<', '>'",
			id,
		)
	}
	return nil
}
