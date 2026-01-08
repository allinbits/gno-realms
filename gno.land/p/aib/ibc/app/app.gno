package app

import (
	"gno.land/p/aib/ibc/types"
)

// IBCApp defines an interface that implements all the callbacks that apps must
// define as specified in IBC Protocol V2.
type IBCApp interface {
	// OnSendPacket is executed when a packet is being sent from sending chain.
	// This callback is provided with the source and destination IDs, the signer,
	// the packet sequence and the packet data for this specific application.
	OnSendPacket(
		cur realm,
		sourceClient string,
		destinationClient string,
		sequence uint64,
		payload types.Payload,
	) error

	// OnRecvPacket is executed when a packet is received from receiving chain.
	//
	// CONTRACT: unlike other functions of this interface, OnRecvPacket does not
	// return an error, this is because in case of error (i.e. when
	// RecvPacketResult.Status == Failure), the underlying transaction is not
	// aborted. So implementer of this interface must keep in mind that any
	// writes to the store and all emitted events in this function aren't not
	// canceled if it returns RecvPacketResult.Status == Failure.
	OnRecvPacket(
		cur realm,
		sourceClient string,
		destinationClient string,
		sequence uint64,
		payload types.Payload,
	) types.RecvPacketResult

	// OnTimeoutPacket is executed when a packet has timed out on the receiving
	// chain.
	OnTimeoutPacket(
		cur realm,
		sourceClient string,
		destinationClient string,
		sequence uint64,
		payload types.Payload,
	) error

	// OnAcknowledgementPacket is executed when a packet gets acknowledged.
	OnAcknowledgementPacket(
		cur realm,
		sourceClient string,
		destinationClient string,
		sequence uint64,
		acknowledgement []byte,
		payload types.Payload,
	) error
}
