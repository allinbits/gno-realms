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
	return mustImpl().SendPacket(0, cur, msg)
}

// RecvPacket verifies the packet commitment proof against the destination
// client, writes the receipt, invokes the app's OnRecvPacket and writes the
// acknowledgement, unless the app answers asynchronously (see
// WriteAcknowledgement). Relayers only.
func RecvPacket(cur realm, msg types.MsgRecvPacket) types.ResponseResultType {
	ensureNotPaused()
	ensureAuthorizedRelayer()
	return mustImpl().RecvPacket(0, cur, msg)
}

// WriteAcknowledgement writes the acknowledgement of a packet whose
// OnRecvPacket returned an async status. Only the realm that registered the
// app for that packet may call it.
func WriteAcknowledgement(cur realm, clientID string, sequence uint64, ack types.Acknowledgement) {
	ensureNotPaused()
	mustImpl().WriteAcknowledgement(0, cur, clientID, sequence, ack)
}

// Acknowledgement verifies the acknowledgement proof against the source
// client, deletes the packet commitment and invokes the app's
// OnAcknowledgementPacket. Relayers only.
func Acknowledgement(cur realm, msg types.MsgAcknowledgement) types.ResponseResultType {
	ensureNotPaused()
	ensureAuthorizedRelayer()
	return mustImpl().Acknowledgement(0, cur, msg)
}

// Timeout verifies the receipt absence proof against the source client,
// deletes the packet commitment and invokes the app's OnTimeoutPacket.
// Relayers only.
func Timeout(cur realm, msg types.MsgTimeout) types.ResponseResultType {
	ensureNotPaused()
	ensureAuthorizedRelayer()
	return mustImpl().Timeout(0, cur, msg)
}
