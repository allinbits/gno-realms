package impl

import (
	"strings"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
)

// The helpers below are impl/v0's (unexported there), unchanged.

// validatePayload enforces the transfer port on both sides, client ids in the
// {string}-{number} format, the ICS20 version and a known encoding.
func validatePayload(sourceClient, destinationClient string, payload types.Payload) error {
	if payload.SourcePort != transfer.PortID || payload.DestinationPort != transfer.PortID {
		return ufmt.Errorf("payload port ID is invalid: expected %s, got sourcePort: %s destPort: %s", transfer.PortID, payload.SourcePort, payload.DestinationPort)
	}
	if !types.IsValidClientID(sourceClient) || !types.IsValidClientID(destinationClient) {
		return ufmt.Errorf("client IDs must be in valid format: {string}-{number}")
	}
	if payload.Version != transfer.V1 {
		return ufmt.Errorf("invalid ICS20 version: expected %s, got %s", transfer.V1, payload.Version)
	}
	if payload.Encoding != transfer.EncodingProtobuf && payload.Encoding != abi.Encoding {
		return ufmt.Errorf("invalid encoding: expected %s or %s, got %s", transfer.EncodingProtobuf, abi.Encoding, payload.Encoding)
	}
	return nil
}

func validatePendingSend(expected transfer.PendingSend, sender, sourceClient, denom string, amount int64) error {
	if expected.Sender != sender ||
		expected.SourceClient != sourceClient ||
		expected.Denom != denom ||
		expected.Amount != amount {
		return ufmt.Errorf("does not match transfer.Transfer")
	}
	return nil
}

// validateBaseDenomNoSlash rejects base denominations containing a slash.
func validateBaseDenomNoSlash(token ics20.Token) error {
	if strings.Contains(token.Denom.Base, "/") {
		return ufmt.Errorf("base denomination %s cannot contain slashes for IBC v2 packet", token.Denom.Base)
	}
	return nil
}

// unmarshalPayload decodes the packet data of payload in its encoding.
func unmarshalPayload(payload types.Payload) (ics20.FungibleTokenPacketData, ics20.Token, error) {
	var (
		data ics20.FungibleTokenPacketData
		err  error
	)
	if payload.Encoding == abi.Encoding {
		data, err = abi.Unmarshal(payload.Value)
	} else {
		err = data.ProtoUnmarshal(payload.Value)
	}
	if err != nil {
		return data, ics20.Token{}, ufmt.Errorf("decoding FungibleTokenPacketData: %v", err)
	}
	if err := data.ValidateBasic(); err != nil {
		return data, ics20.Token{}, ufmt.Errorf("invalid FungibleTokenPacketData: %v", err)
	}
	denom := ics20.ExtractDenomFromPath(data.Denom)
	token := ics20.Token{Denom: denom, Amount: data.Amount}
	return data, token, nil
}
