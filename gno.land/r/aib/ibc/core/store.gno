package core

import (
	"chain/params"

	"gno.land/p/aib/ibc/app/v0"
	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The state of the IBC core lives in this realm forever (see ADR 0001): the
// implementation realm that runs the lifecycle logic only holds a reference
// to it, obtained through RegisterImpl, and reads and writes it through the
// Store and Client interfaces below. Every mutator takes the proxy's own live
// realm value and asserts it (assertProxyRealm): the implementation is always
// invoked non-crossing by the dispatchers, so the value it forwards is this
// realm's cur, and nobody else can present one. The proxy keeps the only
// params.SetBytes calls, inside the commitment, receipt and acknowledgement
// setters, which is what keeps the packet state provable under
// vm:gno.land/r/aib/ibc/core: across upgrades.

// Store is the proxy-owned state as seen by an implementation.
type Store interface {
	// AddClient allocates the next client identifier for typ and stores a
	// client bound to the verifier newLightClient returns. The constructor is
	// called here so the verifier is allocated in this realm: a /p/-declared
	// function such as tendermint.NewTMLightClient runs with the caller's
	// storage authority, whereas an object the implementation allocated
	// itself would belong to the implementation's realm.
	AddClient(_ int, rlm realm, typ string, creator address, newLightClient func() lightclient.Interface) Client
	// Client returns the client with the given identifier, or nil.
	Client(id string) Client
	// ClientIDs returns the known client identifiers, sorted lexically.
	ClientIDs() []string
	// Route returns the application registered on portID; panics if none.
	Route(portID string) App
}

// Client is a stored client as seen by an implementation.
type Client interface {
	ID() string
	Type() string
	Creator() address
	CounterpartyClientID() string
	CounterpartyMerklePrefix() [][]byte
	SetCounterparty(_ int, rlm realm, clientID string, merklePrefix [][]byte)
	LightClient() lightclient.Interface
	// SetLightClient replaces the verifier with convert(current), for a
	// migration to a new light-client version. As for AddClient, convert must
	// be a /p/-declared function so the new verifier is allocated here.
	SetLightClient(_ int, rlm realm, convert func(current lightclient.Interface) lightclient.Interface)
	// NextSendSequence allocates and returns the next send sequence.
	NextSendSequence(_ int, rlm realm) uint64

	PacketCommitment(sequence uint64) []byte
	SetPacketCommitment(_ int, rlm realm, packet types.Packet)
	DeletePacketCommitment(_ int, rlm realm, sequence uint64)

	HasPacketReceipt(sequence uint64) bool
	SetPacketReceipt(_ int, rlm realm, sequence uint64)
	DeletePacketReceipt(_ int, rlm realm, sequence uint64)

	HasPacketAcknowledgement(sequence uint64) bool
	PacketAcknowledgement(sequence uint64) []byte
	SetPacketAcknowledgement(_ int, rlm realm, sequence uint64, ackHash []byte)
	DeletePacketAcknowledgement(_ int, rlm realm, sequence uint64)

	PendingAsyncAck(sequence uint64) (packet types.Packet, appPkgPath string, found bool)
	SavePendingAsyncAck(_ int, rlm realm, packet types.Packet, appPkgPath string)
	DeletePendingAsyncAck(_ int, rlm realm, sequence uint64)
}

// App is a registered application: the IBCApp value plus the realm that
// registered it and its pause flag.
type App struct {
	app.IBCApp
	PkgPath string
	Address address
	// Paused is set by PauseApp: SendPacket refuses the port and RecvPacket
	// answers with the error acknowledgement without invoking the app.
	Paused bool
}

var store *coreStore

func init() {
	store = newStore()
}

type coreStore struct {
	clientSeq  seqid.ID
	clientByID *bptree.BPTree // id:client

	routes map[string]App
	// pendingApps holds registrations from realms outside this project's
	// namespace until the authority approves them (see app.gno). Keyed by
	// pendingKey(port, pkgPath); a B+ tree, because anyone may add to it and
	// a map would be loaded whole on every access.
	pendingApps *bptree.BPTree // port:pkgPath -> App
}

var _ Store = (*coreStore)(nil)

func newStore() *coreStore {
	return &coreStore{
		clientByID:  bptree.NewBPTree32(),
		routes:      make(map[string]App),
		pendingApps: bptree.NewBPTree32(),
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
	packetCommitmentsBySeq      *bptree.BPTree // sequence:commitment
	packetReceiptsBySeq         *bptree.BPTree // sequence:receipt
	packetAcknowledgementsBySeq *bptree.BPTree // sequence:ack
	pendingAsyncAcksBySeq       *bptree.BPTree // sequence:pendingAsyncAck
}

var _ Client = (*client)(nil)

type pendingAsyncAck struct {
	packet     types.Packet
	appPkgPath string
}

func (cs *coreStore) AddClient(_ int, rlm realm, typ string, creator address, newLightClient func() lightclient.Interface) Client {
	assertProxyRealm(0, rlm)
	if newLightClient == nil {
		panic("AddClient: nil light client constructor")
	}
	lc := newLightClient()
	if lc == nil {
		panic("AddClient: nil light client")
	}
	return cs.addClient(typ, creator, lc)
}

func (cs *coreStore) addClient(typ string, creator address, lc lightclient.Interface) *client {
	id := ufmt.Sprintf("%s-%d", typ, uint64(cs.clientSeq.Next()))
	c := &client{
		id:          id,
		typ:         typ,
		creator:     creator,
		lightClient: lc,

		packetCommitmentsBySeq:      bptree.NewBPTree32(),
		packetReceiptsBySeq:         bptree.NewBPTree32(),
		packetAcknowledgementsBySeq: bptree.NewBPTree32(),
		pendingAsyncAcksBySeq:       bptree.NewBPTree32(),
	}
	cs.clientByID.Set(id, c)
	return c
}

func (cs *coreStore) Client(id string) Client {
	c := cs.getClient(id)
	if c == nil {
		return nil
	}
	return c
}

func (cs *coreStore) getClient(id string) *client {
	cli := cs.clientByID.Get(id)
	if cli == nil {
		return nil
	}
	return cli.(*client)
}

func (cs *coreStore) ClientIDs() []string {
	ids := make([]string, 0, cs.clientByID.Size())
	cs.clientByID.IterateByOffset(0, cs.clientByID.Size(), func(k string, _ any) bool {
		ids = append(ids, k)
		return false
	})
	return ids
}

func (cs *coreStore) Route(portID string) App {
	a, ok := cs.routes[portID]
	if !ok {
		panic(ufmt.Sprintf("no registered app for port %s", portID))
	}
	return a
}

func (c *client) ID() string                         { return c.id }
func (c *client) Type() string                       { return c.typ }
func (c *client) Creator() address                   { return c.creator }
func (c *client) CounterpartyClientID() string       { return c.counterpartyClientID }
func (c *client) CounterpartyMerklePrefix() [][]byte { return c.counterpartyMerklePrefix }
func (c *client) LightClient() lightclient.Interface { return c.lightClient }

func (c *client) SetCounterparty(_ int, rlm realm, clientID string, merklePrefix [][]byte) {
	assertProxyRealm(0, rlm)
	c.counterpartyClientID = clientID
	c.counterpartyMerklePrefix = merklePrefix
}

func (c *client) SetLightClient(_ int, rlm realm, convert func(lightclient.Interface) lightclient.Interface) {
	assertProxyRealm(0, rlm)
	if convert == nil {
		panic("SetLightClient: nil converter")
	}
	lc := convert(c.lightClient)
	if lc == nil {
		panic("SetLightClient: nil light client")
	}
	c.lightClient = lc
}

func (c *client) NextSendSequence(_ int, rlm realm) uint64 {
	assertProxyRealm(0, rlm)
	return uint64(c.sendSeq.Next())
}

func (c *client) PacketCommitment(sequence uint64) []byte {
	v := c.packetCommitmentsBySeq.Get(seqid.ID(sequence).Binary())
	if v == nil {
		return nil
	}
	return v.([]byte)
}

// SetPacketCommitment stores the packet commitment in the client data and in
// the params.
func (c *client) SetPacketCommitment(_ int, rlm realm, packet types.Packet) {
	assertProxyRealm(0, rlm)
	commitment := types.CommitPacket(packet)

	// store in client data
	c.packetCommitmentsBySeq.Set(seqid.ID(packet.Sequence).Binary(), commitment)

	// store in params, so it is provable by the counterparty
	// The key will be: (abci path=.store/main/key)
	// "/pv/vm:gno.land/r/aib/ibc/core:" + clientID + "1" + sequence
	key := host.PacketCommitmentKey(c.id, packet.Sequence)
	setChainParam(key, commitment)
}

func (c *client) DeletePacketCommitment(_ int, rlm realm, sequence uint64) {
	assertProxyRealm(0, rlm)
	c.packetCommitmentsBySeq.Remove(seqid.ID(sequence).Binary())

	key := host.PacketCommitmentKey(c.id, sequence)
	setChainParam(key, nil)
}

// HasPacketReceipt returns true if the packet receipt exists, otherwise false.
func (c *client) HasPacketReceipt(sequence uint64) bool {
	return c.packetReceiptsBySeq.Has(seqid.ID(sequence).Binary())
}

// SetPacketReceipt writes the packet receipt under the receipt path
// This is a public path that is standardized by the IBC V2 specification.
func (c *client) SetPacketReceipt(_ int, rlm realm, sequence uint64) {
	assertProxyRealm(0, rlm)
	value := []byte{byte(2)} // constant value

	// store in client data
	c.packetReceiptsBySeq.Set(seqid.ID(sequence).Binary(), value)

	// store in params, so it is provable by the counterparty
	// The key will be: (abci path=.store/main/key)
	// "/pv/vm:gno.land/r/aib/ibc/core:" + clientID + "2" + sequence
	key := host.PacketReceiptKey(c.id, sequence)
	setChainParam(key, value)
}

func (c *client) DeletePacketReceipt(_ int, rlm realm, sequence uint64) {
	assertProxyRealm(0, rlm)
	c.packetReceiptsBySeq.Remove(seqid.ID(sequence).Binary())

	key := host.PacketReceiptKey(c.id, sequence)
	setChainParam(key, nil)
}

// HasPacketAcknowledgement checks if the packet ack hash is already on the
// store.
func (c *client) HasPacketAcknowledgement(sequence uint64) bool {
	return c.packetAcknowledgementsBySeq.Has(seqid.ID(sequence).Binary())
}

// PacketAcknowledgement fetches the packet acknowledgement from the store.
func (c *client) PacketAcknowledgement(sequence uint64) []byte {
	v := c.packetAcknowledgementsBySeq.Get(seqid.ID(sequence).Binary())
	if v == nil {
		return nil
	}
	return v.([]byte)
}

// SetPacketAcknowledgement writes the acknowledgement hash under the
// acknowledgement path
// This is a public path that is standardized by the IBC V2 specification.
func (c *client) SetPacketAcknowledgement(_ int, rlm realm, sequence uint64, ackHash []byte) {
	assertProxyRealm(0, rlm)
	// store in client data
	c.packetAcknowledgementsBySeq.Set(seqid.ID(sequence).Binary(), ackHash)

	// store in params, so it is provable by the counterparty
	// The key will be: (abci path=.store/main/key)
	// "/pv/vm:gno.land/r/aib/ibc/core:" + clientID + "3" + sequence
	key := host.PacketAcknowledgementKey(c.id, sequence)
	setChainParam(key, ackHash)
}

func (c *client) DeletePacketAcknowledgement(_ int, rlm realm, sequence uint64) {
	assertProxyRealm(0, rlm)
	c.packetAcknowledgementsBySeq.Remove(seqid.ID(sequence).Binary())

	key := host.PacketAcknowledgementKey(c.id, sequence)
	setChainParam(key, nil)
}

func (c *client) PendingAsyncAck(sequence uint64) (types.Packet, string, bool) {
	v := c.pendingAsyncAcksBySeq.Get(seqid.ID(sequence).Binary())
	if v == nil {
		return types.Packet{}, "", false
	}
	p := v.(*pendingAsyncAck)
	return p.packet, p.appPkgPath, true
}

func (c *client) SavePendingAsyncAck(_ int, rlm realm, packet types.Packet, appPkgPath string) {
	assertProxyRealm(0, rlm)
	sequence := packet.Sequence
	if c.hasPendingAsyncAck(sequence) {
		panic(ufmt.Sprintf("pending async ack already exists for sequence %d", sequence))
	}
	if c.HasPacketAcknowledgement(sequence) {
		panic(ufmt.Sprintf("acknowledgement already written for sequence %d", sequence))
	}
	c.pendingAsyncAcksBySeq.Set(seqid.ID(sequence).Binary(), &pendingAsyncAck{
		packet:     packet,
		appPkgPath: appPkgPath,
	})
}

func (c *client) DeletePendingAsyncAck(_ int, rlm realm, sequence uint64) {
	assertProxyRealm(0, rlm)
	c.pendingAsyncAcksBySeq.Remove(seqid.ID(sequence).Binary())
}

func (c *client) hasPendingAsyncAck(sequence uint64) bool {
	return c.pendingAsyncAcksBySeq.Has(seqid.ID(sequence).Binary())
}

func setChainParam(key, value []byte) {
	params.SetBytes(string(key), value)
}
