package core

import (
	"chain"
	"encoding/hex"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The Emit* functions below are the single source of truth for the IBC event
// schema. chain.Emit stamps the event with the package whose code contains the
// call, so the implementation emits through them and every event carries
// pkg_path=corePkgPath whichever implementation is active. They are exported
// because the implementation lives in another package, hence the
// assertProxyRealm guard: a foreign realm cannot forge IBC events under this
// realm's pkg_path.

func EmitCreateClient(_ int, rlm realm, clientID, clientType, consensusHeights string) {
	assertProxyRealm(0, rlm)
	chain.Emit(types.EventTypeCreateClient,
		types.AttributeKeyClientID, clientID,
		types.AttributeKeyClientType, clientType,
		types.AttributeKeyConsensusHeights, consensusHeights,
	)
}

func EmitUpdateClient(_ int, rlm realm, clientID, clientType, consensusHeights string) {
	assertProxyRealm(0, rlm)
	chain.Emit(types.EventTypeUpdateClient,
		types.AttributeKeyClientID, clientID,
		types.AttributeKeyClientType, clientType,
		types.AttributeKeyConsensusHeights, consensusHeights,
	)
}

func EmitSubmitMisbehaviour(_ int, rlm realm, clientID, clientType string) {
	assertProxyRealm(0, rlm)
	chain.Emit(types.EventTypeSubmitMisbehaviour,
		types.AttributeKeyClientID, clientID,
		types.AttributeKeyClientType, clientType,
	)
}

func EmitUpgradeClient(_ int, rlm realm, clientID, clientType, consensusHeight string) {
	assertProxyRealm(0, rlm)
	chain.Emit(types.EventTypeUpgradeClient,
		types.AttributeKeyClientID, clientID,
		types.AttributeKeyClientType, clientType,
		types.AttributeKeyConsensusHeight, consensusHeight,
	)
}

func EmitRecoverClient(_ int, rlm realm, subjectClientID, substituteClientID, clientType string) {
	assertProxyRealm(0, rlm)
	chain.Emit(types.EventTypeRecoverClient,
		types.AttributeKeySubjectClientID, subjectClientID,
		types.AttributeKeySubstituteClientID, substituteClientID,
		types.AttributeKeyClientType, clientType,
	)
}

func EmitSendPacket(_ int, rlm realm, packet types.Packet) {
	assertProxyRealm(0, rlm)
	emitPacketEvent(types.EventTypeSendPacket, packet)
}

func EmitRecvPacket(_ int, rlm realm, packet types.Packet) {
	assertProxyRealm(0, rlm)
	emitPacketEvent(types.EventTypeRecvPacket, packet)
}

func EmitAcknowledgePacket(_ int, rlm realm, packet types.Packet) {
	assertProxyRealm(0, rlm)
	emitPacketEvent(types.EventTypeAcknowledgePacket, packet)
}

func EmitTimeoutPacket(_ int, rlm realm, packet types.Packet) {
	assertProxyRealm(0, rlm)
	emitPacketEvent(types.EventTypeTimeoutPacket, packet)
}

func EmitWriteAck(_ int, rlm realm, packet types.Packet, ack types.Acknowledgement) {
	assertProxyRealm(0, rlm)
	chain.Emit(types.EventTypeWriteAck,
		types.AttributeKeySrcClient, packet.SourceClient,
		types.AttributeKeyDstClient, packet.DestinationClient,
		types.AttributeKeySequence, ufmt.Sprintf("%d", packet.Sequence),
		types.AttributeKeyTimeoutTimestamp, ufmt.Sprintf("%d", packet.TimeoutTimestamp),
		types.AttributeKeyEncodedPacketHex, hex.EncodeToString(packet.ProtoMarshal()),
		types.AttributeKeyEncodedAckHex, hex.EncodeToString(ack.ProtoMarshal()),
	)
}

// emitPacketEvent emits the shape shared by the send, recv, acknowledge and
// timeout packet events (they differ only by event type).
func emitPacketEvent(eventType string, packet types.Packet) {
	chain.Emit(eventType,
		types.AttributeKeySrcClient, packet.SourceClient,
		types.AttributeKeyDstClient, packet.DestinationClient,
		types.AttributeKeySequence, ufmt.Sprintf("%d", packet.Sequence),
		types.AttributeKeyTimeoutTimestamp, ufmt.Sprintf("%d", packet.TimeoutTimestamp),
		types.AttributeKeyEncodedPacketHex, hex.EncodeToString(packet.ProtoMarshal()),
	)
}
