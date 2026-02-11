package consumer

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strconv"

	"gno.land/p/aib/ibc/app"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt"
	"gno.land/r/aib/ibc/core"
)

// App implements the app.IBCApp interface for the VAAS consumer.
// It receives validator set change (VSC) packets from the provider chain
// and applies them to the consumer chain's validator set.
//
// The provider sends ValidatorSetChangePacketData packets encoded as JSON with:
//   - SourcePort: "vaas/provider"
//   - DestinationPort: "vaas/consumer"
//   - Version: "1"
//   - Encoding: "application/json"
type App struct{}

const (
	// PortID is the IBC application identifier for the VAAS consumer app.
	PortID = "vaas/consumer"

	// ProviderPortID is the IBC application identifier for the VAAS provider.
	ProviderPortID = "vaas/provider"

	// Version is the IBC application version for the VAAS protocol.
	Version = "1"

	// EncodingJSON is the encoding identifier for JSON-encoded payloads.
	EncodingJSON = "application/json"

	// Param keys for propagating validator set changes to the chain.
	// These follow the approach described in gnolang/gno#3999.
	// Each entry in valset_new / valset_prev is formatted as "pubkey:power".
	paramKeyNewUpdatesAvailable = "new_updates_available"
	paramKeyValsetNew           = "valset_new"
	paramKeyValsetPrev          = "valset_prev"
)

func init() {
	// Register the VAAS consumer app in the IBC router.
	core.RegisterApp(cross, PortID, &App{})
}

var _ app.IBCApp = &App{}

// OnSendPacket implements app.IBCApp.
// The consumer does not send packets — it only receives them.
func (a *App) OnSendPacket(
	_ realm,
	_ banker.Banker,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	return errConsumerNoSend
}

// OnRecvPacket implements app.IBCApp.
//
// Receives VSC packets from the provider, validates them, accumulates
// changes with any existing pending updates, and applies them to the
// cross-chain validator set.
//
// Out-of-order packet handling is supported: if a packet arrives with a
// ValsetUpdateId <= the highest already processed, it is acknowledged
// (success) but not applied.
func (a *App) OnRecvPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) types.RecvPacketResult {
	// Validate payload ports.
	if payload.SourcePort != ProviderPortID {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if payload.DestinationPort != PortID {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}

	// Validate client IDs are in the expected format.
	if !types.IsValidClientID(sourceClient) || !types.IsValidClientID(destinationClient) {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}

	// Validate version and encoding.
	if payload.Version != Version {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if payload.Encoding != EncodingJSON {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}

	// Decode the VSC packet data.
	vscData, err := UnmarshalValidatorSetChangePacketData(payload.Value)
	if err != nil {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}

	// Validate the packet data.
	if err := vscData.Validate(); err != nil {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}

	// Check for out-of-order / stale packets.
	highestID := GetHighestValsetUpdateID()
	if vscData.ValsetUpdateId <= highestID {
		// Return success ack without processing — the packet is stale
		ack := types.NewResultAppAcknowledgement([]byte{byte(1)})
		return types.RecvPacketResult{
			Status:          types.PacketStatus_Success,
			Acknowledgement: ack.MarshalJSON(),
		}
	}

	// Track the provider client ID. On the first packet, record it and emit
	// a channel established event. On subsequent packets, verify it matches.
	providerClient, hasProvider := GetProviderClientID()
	if hasProvider && providerClient != sourceClient {
		// Packet from a different client than the established provider — reject.
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if !hasProvider {
		setProviderClientID(sourceClient)

		chain.Emit(EventTypeChannelEstablished,
			AttributeKeyModule, ModuleName,
			"client_id", sourceClient,
			"routing_mode", "ibc_v2",
		)
	}

	// Accumulate changes: merge new updates with any previously pending ones.
	currentPending := getPendingChanges()
	if currentPending == nil {
		currentPending = []ValidatorUpdate{}
	}
	accumulated := AccumulateChanges(currentPending, vscData.ValidatorUpdates)

	// Apply the accumulated changes to the cross-chain validator set.
	applied := applyValidatorChanges(accumulated)
	_ = applied

	// Clear pending changes since they've been applied.
	clearPendingChanges()

	// Record the valset update ID.
	setLastValsetUpdateID(vscData.ValsetUpdateId)

	// Update the highest valset update ID for out-of-order packet tracking.
	setHighestValsetUpdateID(vscData.ValsetUpdateId)

	// Map the next block height to this valset update ID.
	nextHeight := uint64(runtime.ChainHeight()) + 1
	setHeightValsetUpdateID(nextHeight, vscData.ValsetUpdateId)

	// Propagate the updated validator set via params so that the chain's
	// EndBlocker can pick up the changes (per gnolang/gno#3999).
	//
	// TODO(gnolang/gno#3999): Uncomment the following lines once
	// std.SetParamBool and std.SetParamStrings are available:
	//
	//   newValset := serializeValidatorSet()
	//   std.SetParamStrings(paramKeyValsetNew, newValset)
	//   std.SetParamBool(paramKeyNewUpdatesAvailable, true)

	// Emit events.
	chain.Emit(EventTypeVSCPacket,
		AttributeKeyValsetUpdateID, strconv.FormatUint(vscData.ValsetUpdateId, 10),
		AttributeKeyNumUpdates, strconv.Itoa(len(vscData.ValidatorUpdates)),
		AttributeKeyAckSuccess, "true",
		"routing_mode", "ibc_v2",
		"source_client", sourceClient,
	)

	// Return success acknowledgement.
	ack := types.NewResultAppAcknowledgement([]byte{byte(1)})
	return types.RecvPacketResult{
		Status:          types.PacketStatus_Success,
		Acknowledgement: ack.MarshalJSON(),
	}
}

// OnTimeoutPacket implements app.IBCApp.
// The consumer does not send packets, so timeout handling is a no-op.
func (a *App) OnTimeoutPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	chain.Emit(EventTypeTimeout,
		AttributeKeyModule, ModuleName,
		"source_client", sourceClient,
		"destination_client", destinationClient,
		"sequence", ufmt.Sprintf("%d", sequence),
	)
	return nil
}

// OnAcknowledgementPacket implements app.IBCApp.
// The consumer does not send packets, so acknowledgement handling is a no-op.
func (a *App) OnAcknowledgementPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	acknowledgement []byte,
	payload types.Payload,
) error {
	chain.Emit(EventTypeAcknowledgement,
		AttributeKeyModule, ModuleName,
		"source_client", sourceClient,
		"destination_client", destinationClient,
		"sequence", ufmt.Sprintf("%d", sequence),
	)
	return nil
}
