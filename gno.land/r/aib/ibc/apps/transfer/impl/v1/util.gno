package impl

import (
	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
)

// validatePayload enforces the transfer port on both sides, the local client
// id in the {string}-{number} format and the Ethereum router's client id in
// its own grammar (types.IsValidRouterClientID: "client-N" or a custom id
// such as "gnoland"), the ICS20 version and a known encoding.
func validatePayload(localClient, routerClient string, payload types.Payload) error {
	if payload.SourcePort != transfer.PortID || payload.DestinationPort != transfer.PortID {
		return ufmt.Errorf("payload port ID is invalid: expected %s, got sourcePort: %s destPort: %s", transfer.PortID, payload.SourcePort, payload.DestinationPort)
	}
	if !types.IsValidClientID(localClient) {
		return ufmt.Errorf("client ID %s must be in valid format: {string}-{number}", localClient)
	}
	if !types.IsValidRouterClientID(routerClient) {
		return ufmt.Errorf("client ID %s is no Ethereum router client id", routerClient)
	}
	if payload.Version != transfer.V1 {
		return ufmt.Errorf("invalid ICS20 version: expected %s, got %s", transfer.V1, payload.Version)
	}
	if payload.Encoding != transfer.EncodingProtobuf && payload.Encoding != abi.Encoding {
		return ufmt.Errorf("invalid encoding: expected %s or %s, got %s", transfer.EncodingProtobuf, abi.Encoding, payload.Encoding)
	}
	return nil
}

// unmarshalPayload decodes the packet data of payload, sent or received on
// an Ethereum route whose router names gno.land's client routerClient, in
// its encoding.
func unmarshalPayload(routerClient string, payload types.Payload) (ics20.FungibleTokenPacketData, ics20.Token, error) {
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
	// An Ethereum route's data is validated by its own rules only
	// (ValidateBasicEthereum), not the SDK's first: the router's client id
	// as a hop, of up to 128 characters, or a blank receiver (an owed
	// sweep), is valid here.
	denom, err := data.ValidateBasicEthereum(routerClient)
	if err != nil {
		return data, ics20.Token{}, ufmt.Errorf("invalid FungibleTokenPacketData: %v", err)
	}
	token := ics20.Token{Denom: denom, Amount: data.Amount}
	return data, token, nil
}
