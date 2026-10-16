package core

import (
	"gno.land/p/aib/ibc/types/v0"
)

// The packet entry points below are thin dispatchers to the active
// implementation (see upgrade.gno): the gates that must survive any
// implementation run here, then the call is forwarded non-crossing with this
// realm's own cur, so the current realm stays this proxy.

// SendPacket validates msg, stores the packet commitment, emits send_packet
// and invokes each payload app's OnSendPacket. Returns the packet sequence.
func SendPacket(cur realm, msg types.MsgSendPacket) (sequence uint64) {
	ensureNotPaused()
	ensureNotRetired(msg.SourceClient)
	return mustImpl().SendPacket(0, cur, msg)
}

// RecvPacket verifies the packet commitment proof against the destination
// client, writes the receipt, invokes the app's OnRecvPacket and writes the
// acknowledgement, unless the app answers asynchronously (see
// WriteAcknowledgement). Relayers only, except for an Ethereum client, whose
// relaying is permissionless (see ensureRelayerFor).
func RecvPacket(cur realm, msg types.MsgRecvPacket) types.ResponseResultType {
	ensureNotPaused()
	ensureNotRetired(msg.Packet.DestinationClient)
	ensureRelayerFor(msg.Packet.DestinationClient)
	return mustImpl().RecvPacket(0, cur, msg)
}

// WriteAcknowledgement writes the acknowledgement of a packet whose
// OnRecvPacket returned an async status. Only the realm that registered the
// app for that packet may call it. A retired client still takes it for a
// packet it received before its retirement: the app finalizes the receipt it
// already holds, so the packet reaches a terminal state before the
// reconciliation (ADR pr6375 §7.12); nothing new is received there.
func WriteAcknowledgement(cur realm, clientID string, sequence uint64, ack types.Acknowledgement) {
	ensureNotPaused()
	if !HasPendingAsyncAck(clientID, sequence) {
		ensureNotRetired(clientID)
	}
	mustImpl().WriteAcknowledgement(0, cur, clientID, sequence, ack)
}

// Acknowledgement verifies the acknowledgement proof against the source
// client, deletes the packet commitment and invokes the app's
// OnAcknowledgementPacket. Relayers only, except for an Ethereum client (see
// ensureRelayerFor): a refund never waits on a listed relayer.
func Acknowledgement(cur realm, msg types.MsgAcknowledgement) types.ResponseResultType {
	ensureNotPaused()
	ensureNotRetired(msg.Packet.SourceClient)
	ensureRelayerFor(msg.Packet.SourceClient)
	return mustImpl().Acknowledgement(0, cur, msg)
}

// Timeout verifies the receipt absence proof against the source client,
// deletes the packet commitment and invokes the app's OnTimeoutPacket.
// Relayers only, except for an Ethereum client (see ensureRelayerFor).
func Timeout(cur realm, msg types.MsgTimeout) types.ResponseResultType {
	ensureNotPaused()
	ensureNotRetired(msg.Packet.SourceClient)
	ensureRelayerFor(msg.Packet.SourceClient)
	return mustImpl().Timeout(0, cur, msg)
}
