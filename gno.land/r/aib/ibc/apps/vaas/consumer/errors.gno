package consumer

import (
	"errors"
)

// Errors
var (
	errNilValidatorUpdates   = errors.New("validator updates cannot be nil")
	errZeroValsetUpdateId    = errors.New("valset update id cannot be zero")
	errEmptyPubKey           = errors.New("validator public key cannot be empty")
	errInvalidPubKey         = errors.New("validator public key has invalid format")
	errConsumerNoSend        = errors.New("consumer app does not send packets")
	errStaleVSCPacket        = errors.New("stale or out-of-order VSC packet")
	errInvalidProviderClient = errors.New("VSC packet from unexpected provider client")
)

// Event types emitted by the consumer app.
const (
	EventTypeVSCPacket          = "vaas_packet"
	EventTypeValsetUpdate       = "vaas_valset_update"
	EventTypeTimeout            = "timeout"
	EventTypeAcknowledgement    = "vaas_acknowledgement"
	EventTypeChannelEstablished = "channel_established"
)

// Event attribute keys.
const (
	AttributeKeyValsetUpdateID = "valset_update_id"
	AttributeKeyNumUpdates     = "num_updates"
	AttributeKeyAckSuccess     = "success"
	AttributeKeyAckError       = "error"
	AttributeKeyModule         = "module"
)

// ModuleName is the name of the VAAS consumer module.
const ModuleName = "vaasconsumer"
