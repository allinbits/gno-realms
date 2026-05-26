package core

import (
	"bytes"
	"testing"

	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/uassert/v0"
)

const asyncAckTestCallerPath = "gno.land/r/aib/ibc/core"

func TestWriteAcknowledgementSuccess(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	ack := newAsyncAckTestAck()

	c.savePendingAsyncAck(packet, asyncAckTestCallerPath)

	WriteAcknowledgement(cross(cur), c.id, packet.Sequence, ack)

	uassert.False(t, c.hasPendingAsyncAck(packet.Sequence))
	uassert.True(t, c.hasPacketAcknowledgement(packet.Sequence))
	if !bytes.Equal(types.CommitAcknowledgement(ack), c.getPacketAcknowledgement(packet.Sequence)) {
		t.Fatal("unexpected acknowledgement commitment")
	}
}

func TestWriteAcknowledgementWithoutAsyncRejected(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()

	uassert.AbortsContains(t, cur, "no pending async ack", func() {
		WriteAcknowledgement(cross(cur), c.id, 1, newAsyncAckTestAck())
	})
}

func TestWriteAcknowledgementWrongCallerPreservesPending(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	c.savePendingAsyncAck(packet, "gno.land/r/aib/ibc/not-the-caller")

	uassert.AbortsContains(t, cur, "is not authorized to write ack", func() {
		WriteAcknowledgement(cross(cur), c.id, packet.Sequence, newAsyncAckTestAck())
	})

	uassert.True(t, c.hasPendingAsyncAck(packet.Sequence))
	uassert.False(t, c.hasPacketAcknowledgement(packet.Sequence))
}

func TestWriteAcknowledgementDuplicateRejected(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	c.savePendingAsyncAck(packet, asyncAckTestCallerPath)

	WriteAcknowledgement(cross(cur), c.id, packet.Sequence, newAsyncAckTestAck())

	uassert.AbortsContains(t, cur, "no pending async ack", func() {
		WriteAcknowledgement(cross(cur), c.id, packet.Sequence, newAsyncAckTestAck())
	})
}

func TestWriteAcknowledgementAlreadyAckedRejected(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	ack := newAsyncAckTestAck()
	c.savePendingAsyncAck(packet, asyncAckTestCallerPath)
	c.setPacketAcknowledgement(packet.Sequence, types.CommitAcknowledgement(ack))

	uassert.AbortsContains(t, cur, "acknowledgement already written", func() {
		WriteAcknowledgement(cross(cur), c.id, packet.Sequence, ack)
	})

	uassert.True(t, c.hasPendingAsyncAck(packet.Sequence))
}

func TestPendingAsyncAckStoreRoundTrip(t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 7)

	c.savePendingAsyncAck(packet, asyncAckTestCallerPath)

	pending, found := c.getPendingAsyncAck(packet.Sequence)
	uassert.True(t, found)
	uassert.Equal(t, asyncAckTestCallerPath, pending.appPkgPath)
	uassert.Equal(t, packet.Sequence, pending.packet.Sequence)
	uassert.Equal(t, packet.SourceClient, pending.packet.SourceClient)
	uassert.Equal(t, packet.DestinationClient, pending.packet.DestinationClient)

	c.deletePendingAsyncAck(packet.Sequence)
	uassert.False(t, c.hasPendingAsyncAck(packet.Sequence))
}

func TestRecvPacketAsyncDefersAck(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	store.routes["appID"] = ibcApp{
		IBCApp: &asyncAckTestApp{res: types.RecvPacketResult{
			Status: types.PacketStatus_Async,
		}},
		pkgPath: asyncAckTestCallerPath,
	}

	c.writeRecvPacketAcknowledgement(0, cur, packet)

	uassert.True(t, c.hasPendingAsyncAck(packet.Sequence))
	uassert.False(t, c.hasPacketAcknowledgement(packet.Sequence))
}

func TestRecvPacketMultiPayloadAsyncRejected(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	packet.Payloads = append(packet.Payloads, packet.Payloads[0])
	store.routes["appID"] = ibcApp{
		IBCApp: &asyncAckTestApp{res: types.RecvPacketResult{
			Status: types.PacketStatus_Async,
		}},
		pkgPath: asyncAckTestCallerPath,
	}

	uassert.PanicsContains(t, cur, "async ack not supported for multi-payload packets", func() {
		c.writeRecvPacketAcknowledgement(0, cur, packet)
	})
}

func TestRecvPacketSuccessWritesAck(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	ack := []byte{0x02}
	store.routes["appID"] = ibcApp{
		IBCApp: &asyncAckTestApp{res: types.RecvPacketResult{
			Status:          types.PacketStatus_Success,
			Acknowledgement: ack,
		}},
		pkgPath: asyncAckTestCallerPath,
	}

	c.writeRecvPacketAcknowledgement(0, cur, packet)

	uassert.False(t, c.hasPendingAsyncAck(packet.Sequence))
	uassert.True(t, c.hasPacketAcknowledgement(packet.Sequence))
}

func TestSavePendingAsyncAckRejectsDuplicate(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	c.savePendingAsyncAck(packet, asyncAckTestCallerPath)

	uassert.PanicsContains(t, cur, "pending async ack already exists", func() {
		c.savePendingAsyncAck(packet, asyncAckTestCallerPath)
	})
}

func TestSavePendingAsyncAckRejectsAlreadyAcked(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	ack := newAsyncAckTestAck()
	c.setPacketAcknowledgement(packet.Sequence, types.CommitAcknowledgement(ack))

	uassert.PanicsContains(t, cur, "acknowledgement already written", func() {
		c.savePendingAsyncAck(packet, asyncAckTestCallerPath)
	})
}

func newAsyncAckTestClient() *client {
	store = newStore()
	c := store.addClient(lightclient.Tendermint, address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"))
	c.counterpartyClientID = "07-tendermint-42"
	return c
}

func newAsyncAckTestPacket(destinationClient string, sequence uint64) types.Packet {
	return types.Packet{
		Sequence:          sequence,
		SourceClient:      "07-tendermint-42",
		DestinationClient: destinationClient,
		TimeoutTimestamp:  1234567890,
		Payloads: []types.Payload{{
			SourcePort:      "appID",
			DestinationPort: "appID",
			Version:         "v1",
			Encoding:        "application/json",
			Value:           []byte("{}"),
		}},
	}
}

func newAsyncAckTestAck() types.Acknowledgement {
	return types.Acknowledgement{
		AppAcknowledgements: [][]byte{{0x01}},
	}
}

type asyncAckTestApp struct {
	res types.RecvPacketResult
}

func (a *asyncAckTestApp) OnSendPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	return nil
}

func (a *asyncAckTestApp) OnRecvPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) types.RecvPacketResult {
	return a.res
}

func (a *asyncAckTestApp) OnTimeoutPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	return nil
}

func (a *asyncAckTestApp) OnAcknowledgementPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	acknowledgement []byte,
	payload types.Payload,
) error {
	return nil
}
