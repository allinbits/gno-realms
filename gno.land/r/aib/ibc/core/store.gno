package core

import (
	"chain/params"

	"gno.land/p/aib/ibc/app"
	"gno.land/p/aib/ibc/host"
	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/avl"
	"gno.land/p/nt/seqid"
	"gno.land/p/nt/ufmt"
)

var store *Store

func init() {
	store = newStore()
}

type Store struct {
	clientSeq  seqid.ID
	clientByID *avl.Tree // id:client

	routes map[string]ibcApp
}

func newStore() *Store {
	return &Store{
		clientByID: avl.NewTree(),
		routes:     make(map[string]ibcApp),
	}
}

type client struct {
	id                       string
	typ                      string
	creator                  address
	counterpartyClientID     string
	counterpartyMerklePrefix [][]byte

	lightClient lightclient.Interface

	sendSeq                     seqid.ID
	packetCommitmentsBySeq      *avl.Tree // sequence:commitment
	packetReceiptsBySeq         *avl.Tree // sequence:receipt
	packetAcknowledgementsBySeq *avl.Tree // sequence:ack
}

type ibcApp struct {
	app.IBCApp
	pkgPath string
	address address
}

func (c *client) getPacketCommitment(sequence uint64) []byte {
	v, found := c.packetCommitmentsBySeq.Get(seqid.ID(sequence).Binary())
	if !found {
		return nil
	}
	return v.([]byte)
}

// setPacketCommitment stores the packet commitment in the client data and in
// the params.
func (c *client) setPacketCommitment(sequence uint64, packet types.Packet) {
	commitment := types.CommitPacket(packet)

	// store in client data
	c.packetCommitmentsBySeq.Set(seqid.ID(sequence).Binary(), commitment)

	// store in params, so it is provable by the counterparty
	// The param key will be:
	// "vm:gno.land/r/aib/ibc/core:" + clientID + "1" + sequence
	key := host.PacketCommitmentKey(c.id, sequence)
	// TODO find a way to assert this write in tests (difficult since params does
	// not expose getters)
	params.SetBytes(string(key), commitment)
}

func (c *client) deletePacketCommitment(sequence uint64) {
	c.packetCommitmentsBySeq.Remove(seqid.ID(sequence).Binary())

	key := host.PacketCommitmentKey(c.id, sequence)
	// TODO find a way to assert this write in tests (difficult since params does
	// not expose getters)
	params.SetBytes(string(key), nil)
}

// hasPacketReceipt returns true if the packet receipt exists, otherwise false.
func (c *client) hasPacketReceipt(sequence uint64) bool {
	return c.packetReceiptsBySeq.Has(seqid.ID(sequence).Binary())
}

// setPacketReceipt writes the packet receipt under the receipt path
// This is a public path that is standardized by the IBC V2 specification.
func (c *client) setPacketReceipt(sequence uint64) {
	value := []byte{byte(2)} // constant value

	// store in client data
	c.packetReceiptsBySeq.Set(seqid.ID(sequence).Binary(), value)

	// store in params, so it is provable by the counterparty
	// The param key will be:
	// "vm:gno.land/r/aib/ibc/core:" + clientID + "2" + sequence
	key := host.PacketReceiptKey(c.id, sequence)
	// TODO find a way to assert this write in tests (difficult since params does
	// not expose getters)
	params.SetBytes(string(key), value)
}

func (c *client) deletePacketReceipt(sequence uint64) {
	c.packetReceiptsBySeq.Remove(seqid.ID(sequence).Binary())

	key := host.PacketReceiptKey(c.id, sequence)
	// TODO find a way to assert this write in tests (difficult since params does
	// not expose getters)
	params.SetBytes(string(key), nil)
}

// hasPacketAcknowledgement checks if the packet ack hash is already on the
// store.
func (c *client) hasPacketAcknowledgement(sequence uint64) bool {
	return c.packetAcknowledgementsBySeq.Has(seqid.ID(sequence).Binary())
}

// GetPacketAcknowledgement fetches the packet acknowledgement from the store.
func (c *client) getPacketAcknowledgement(sequence uint64) []byte {
	v, found := c.packetAcknowledgementsBySeq.Get(seqid.ID(sequence).Binary())
	if !found {
		return nil
	}
	return v.([]byte)
}

// SetPacketAcknowledgement writes the acknowledgement hash under the
// acknowledgement path
// This is a public path that is standardized by the IBC V2 specification.
func (c *client) setPacketAcknowledgement(sequence uint64, ackHash []byte) {
	// store in client data
	c.packetAcknowledgementsBySeq.Set(seqid.ID(sequence).Binary(), ackHash)

	// store in params, so it is provable by the counterparty
	// The param key will be:
	// "vm:gno.land/r/aib/ibc/core:" + clientID + "2" + sequence
	key := host.PacketAcknowledgementKey(c.id, sequence)
	// TODO find a way to assert this write in tests (difficult since params does
	// not expose getters)
	params.SetBytes(string(key), ackHash)
}

func (c *client) deletePacketAcknowledgement(sequence uint64) {
	c.packetAcknowledgementsBySeq.Remove(seqid.ID(sequence).Binary())

	key := host.PacketAcknowledgementKey(c.id, sequence)
	// TODO find a way to assert this write in tests (difficult since params does
	// not expose getters)
	params.SetBytes(string(key), nil)
}

func (cs *Store) addClient(typ string, creator address) *client {
	id := ufmt.Sprintf("%s-%d", typ, uint64(cs.clientSeq.Next()))
	c := &client{
		id:      id,
		typ:     typ,
		creator: creator,

		packetCommitmentsBySeq:      avl.NewTree(),
		packetReceiptsBySeq:         avl.NewTree(),
		packetAcknowledgementsBySeq: avl.NewTree(),
	}
	switch typ {
	case lightclient.Tendermint:
		c.lightClient = &tendermint.TMLightClient{}
	default:
		panic("unhandled light client type " + typ)
	}
	cs.clientByID.Set(id, c)
	return c
}

func (cs *Store) getClient(id string) *client {
	x, found := cs.clientByID.Get(id)
	if !found {
		return nil
	}
	return x.(*client)
}

// route returns an IBCApp for the given portID.
func (cs *Store) route(portID string) ibcApp {
	app, ok := cs.routes[portID]
	if !ok {
		panic(ufmt.Sprintf("no registered app for port %s", portID))
	}
	return app
}
