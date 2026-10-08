package core

import (
	"testing"

	"gno.land/p/aib/ibc/lightclient/tendermint/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/uassert/v0"
)

// The async acknowledgement flow through the entry points (RecvPacket with an
// async app, WriteAcknowledgement and its caller gate) is covered by the z10*
// filetests, which run through the installed implementation. The tests below
// cover the proxy-owned pending-ack store.

const asyncAckTestCallerPath = "gno.land/r/aib/ibc/core"

func TestPendingAsyncAckStoreRoundTrip(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 7)

	c.SavePendingAsyncAck(0, cur, packet, asyncAckTestCallerPath)

	pending, appPkgPath, found := c.PendingAsyncAck(packet.Sequence)
	uassert.True(t, found)
	uassert.Equal(t, asyncAckTestCallerPath, appPkgPath)
	uassert.Equal(t, packet.Sequence, pending.Sequence)
	uassert.Equal(t, packet.SourceClient, pending.SourceClient)
	uassert.Equal(t, packet.DestinationClient, pending.DestinationClient)

	c.DeletePendingAsyncAck(0, cur, packet.Sequence)
	_, _, found = c.PendingAsyncAck(packet.Sequence)
	uassert.False(t, found)
}

func TestSavePendingAsyncAckRejectsDuplicate(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	c.SavePendingAsyncAck(0, cur, packet, asyncAckTestCallerPath)

	uassert.PanicsContains(t, cur, "pending async ack already exists", func() {
		c.SavePendingAsyncAck(0, cur, packet, asyncAckTestCallerPath)
	})
}

func TestSavePendingAsyncAckRejectsAlreadyAcked(cur realm, t *testing.T) {
	c := newAsyncAckTestClient()
	packet := newAsyncAckTestPacket(c.id, 1)
	ack := newAsyncAckTestAck()
	c.SetPacketAcknowledgement(0, cur, packet.Sequence, types.CommitAcknowledgement(ack))

	uassert.PanicsContains(t, cur, "acknowledgement already written", func() {
		c.SavePendingAsyncAck(0, cur, packet, asyncAckTestCallerPath)
	})
}

func newAsyncAckTestClient() *client {
	store = newStore()
	c := store.addClient(lightclient.Tendermint, address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"), tendermint.NewTMLightClient())
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
