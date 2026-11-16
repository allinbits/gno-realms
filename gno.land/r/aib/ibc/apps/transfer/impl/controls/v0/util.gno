package controls

import (
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	ics20impl "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v0"
)

// validateRouterPayload is ics20impl.ValidatePayloadShape plus the local
// client id in the {string}-{number} format and the router's client id in
// its own grammar (types.IsValidRouterClientID: "client-N" or a custom id
// such as "gnoland").
func validateRouterPayload(localClient, routerClient string, payload types.Payload) error {
	if err := ics20impl.ValidatePayloadShape(payload); err != nil {
		return err
	}
	if !types.IsValidClientID(localClient) {
		return ufmt.Errorf("client ID %s must be in valid format: {string}-{number}", localClient)
	}
	if !types.IsValidRouterClientID(routerClient) {
		return ufmt.Errorf("client ID %s is no Ethereum router client id", routerClient)
	}
	return nil
}

// unmarshalRouterPayload decodes the packet data of payload, sent or
// received on an Ethereum route whose router names gno.land's client
// routerClient (ics20impl.DecodePacketData), and validates it by the route's
// rules.
func unmarshalRouterPayload(routerClient string, payload types.Payload) (ics20.FungibleTokenPacketData, ics20.Token, error) {
	data, err := ics20impl.DecodePacketData(payload)
	if err != nil {
		return data, ics20.Token{}, err
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
