package consumer

import (
	"errors"
)

// Errors
var (
	errNilValidatorUpdates = errors.New("validator updates cannot be nil")
	errZeroValsetUpdateId  = errors.New("valset update id cannot be zero")
	errEmptyPubKey         = errors.New("validator public key cannot be empty")
	errInvalidPubKey       = errors.New("validator public key has invalid format")
	errNegativePower       = errors.New("validator power cannot be negative")
	errConsumerNoSend      = errors.New("consumer app does not send packets")
)

// Event types emitted by the consumer app.
const (
	EventTypeVSCPacket          = "vaas_packet"
	EventTypeTimeout            = "timeout"
	EventTypeAcknowledgement    = "vaas_acknowledgement"
	EventTypeChannelEstablished = "channel_established"
)

// Event attribute keys.
const (
	AttributeKeyValsetUpdateID = "valset_update_id"
	AttributeKeyNumUpdates     = "num_updates"
	AttributeKeyAckSuccess     = "success"
	AttributeKeyModule         = "module"
)

// ModuleName is the name of the VAAS consumer module.
const ModuleName = "vaasconsumer"
