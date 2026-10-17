package core

import (
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The client entry points below are thin dispatchers to the active
// implementation (see upgrade.gno and core.gno).

// CreateClient generates a new client identifier and initializes the light
// client with the given states. Relayers only; the relayer becomes the
// client's creator.
func CreateClient(cur realm, clientState lightclient.ClientState, consensusState lightclient.ConsensusState) string {
	relayer := ensureAuthorizedRelayer()
	return mustImpl().CreateClient(0, cur, relayer, clientState, consensusState)
}

// ClientIDs returns the list of known client identifiers, sorted lexically by
// id (the underlying b+tree order). Intended for read-only callers (UIs,
// other realms building txlinks).
func ClientIDs() []string {
	return store.ClientIDs()
}

// ClientLatestHeight returns the latest (highest) consensus height the given
// client has been updated to, formatted as "<revision>/<height>". This is the
// client's latest trusted height. Returns "" if the client is unknown.
// Intended for read-only callers (UIs) that want to surface how up-to-date a
// client is.
func ClientLatestHeight(clientID string) string {
	c := store.getClient(clientID)
	if c == nil {
		return ""
	}
	return c.lightClient.LatestHeight().String()
}

// ClientStatus returns the status of the given client (Active, Expired,
// Frozen, ...). Returns "" if the client is unknown. Intended for read-only
// callers (UIs) that want to surface whether a client is usable.
func ClientStatus(clientID string) string {
	c := store.getClient(clientID)
	if c == nil {
		return ""
	}
	return c.lightClient.Status()
}

// RegisterCounterparty will register the IBC v2 counterparty info for the
// given clientID. It must be called by the same relayer that called
// CreateClient.
func RegisterCounterparty(cur realm, clientID string, counterpartyMerklePrefix [][]byte, counterpartyClientID string) {
	ensureNotRetired(clientID)
	mustImpl().RegisterCounterparty(0, cur, clientID, counterpartyMerklePrefix, counterpartyClientID)
}

// UpdateClient will update the given IBC v2 light client with a new header.
// Can also be used to submit a misbehavior (clientMessage can be a header or
// a misbehavior). Relayers only, except for an Ethereum client, whose updates
// anyone may submit (see ensureRelayerFor): a refund needs a fresh client.
func UpdateClient(cur realm, clientID string, clientMessage lightclient.ClientMessage) {
	ensureNotRetired(clientID)
	ensureRelayerFor(clientID)
	c := store.getClient(clientID)
	frozen := c != nil && c.lightClient.Status() == lightclient.Frozen
	mustImpl().UpdateClient(0, cur, clientID, clientMessage)
	// A misbehaviour that froze the client ends its trust generation.
	if c != nil && !frozen && c.lightClient.Status() == lightclient.Frozen {
		c.trustGen++
	}
}

// UpgradeClient upgrades the client to a new client and consensus state,
// verified by proofs that the counterparty chain committed to those states
// at its UpgradePath under the current client's latest consensus root.
// Relayers only.
func UpgradeClient(cur realm, clientID string, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState any) {
	ensureNotRetired(clientID)
	ensureAuthorizedRelayer()
	mustImpl().UpgradeClient(0, cur, clientID, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState)
	newTrustGeneration(clientID)
}

// RecoverClient recovers a frozen or expired subject client using a healthy
// substitute client that tracks the same counterparty chain. Governance only
// (ADR pr6375 R14): a recovery trusts the substitute, so it waits for its
// decision's delay in ibcgov.
func RecoverClient(cur realm, subjectClientID, substituteClientID string) {
	assertGovernance(0, cur, "recover_client")
	ensureNotRetired(subjectClientID)
	ensureNotRetired(substituteClientID)
	mustImpl().RecoverClient(0, cur, subjectClientID, substituteClientID)
	newTrustGeneration(subjectClientID)
}

// newTrustGeneration starts a new trust generation of clientID's verifier,
// after a call that changed whom it trusts. The core does it itself rather
// than leave it to the implementation, which an upgrade replaces.
func newTrustGeneration(clientID string) {
	if c := store.getClient(clientID); c != nil {
		c.trustGen++
	}
}

// ClientTrustGeneration is clientID's trust generation (0 if unknown): it
// grows on each recovery, freeze, upgrade, migration and substitution of the
// verifier, so an outcome proven through the client is settled on only while
// the generation it was proven under is current (ADR pr6375 §5.4).
func ClientTrustGeneration(clientID string) uint64 {
	c := store.getClient(clientID)
	if c == nil {
		return 0
	}
	return c.trustGen
}

// recoveryChecker is implemented by a light client that tells, without a
// change, why it would refuse a recovery from substitute.
type recoveryChecker interface {
	CheckRecovery(substitute lightclient.Interface) error
}

// CheckRecoverClient is why RecoverClient(subjectClientID, substituteClientID)
// would fail now, or "": every check of the core and of the subject's light
// client, with no change. A governed recovery that would fail is refused (and
// its decision spent) instead of aborting and staying pending.
func CheckRecoverClient(subjectClientID, substituteClientID string) string {
	subject, substitute := store.getClient(subjectClientID), store.getClient(substituteClientID)
	switch {
	case subjectClientID == substituteClientID:
		return "the subject and the substitute are one client"
	case subject == nil || substitute == nil:
		return "unknown client"
	case store.isRetired(subjectClientID) || store.isRetired(substituteClientID):
		return "a retired client is never recovered or used to recover"
	case subject.Type() != substitute.Type():
		return "the subject and the substitute are of different types"
	}
	if status := subject.LightClient().Status(); status != lightclient.Frozen && status != lightclient.Expired {
		return "client " + subjectClientID + " is " + string(status) + ", not frozen or expired"
	}
	if status := substitute.LightClient().Status(); status != lightclient.Active {
		return "substitute " + substituteClientID + " is " + string(status) + ", not Active"
	}
	if rc, ok := subject.LightClient().(recoveryChecker); ok {
		if err := rc.CheckRecovery(substitute.LightClient()); err != nil {
			return err.Error()
		}
	}
	return ""
}

// ClientMigrationChecker is implemented by a ClientMigrator that tells,
// without a change, why a migration would fail.
type ClientMigrationChecker interface {
	CheckMigrateClient(clientID, migration string, params []byte) error
}

// CheckMigrateClient is why MigrateClient(clientID, migration, params) would
// fail now, or "", with no change: a governed migration that would fail is
// refused (and its decision spent) instead of aborting and staying pending.
func CheckMigrateClient(clientID, migration string, params []byte) string {
	if store.getClient(clientID) == nil {
		return "unknown client " + clientID
	}
	if store.isRetired(clientID) {
		return "client " + clientID + " is retired"
	}
	m, ok := mustImpl().(ClientMigrationChecker)
	if !ok {
		return "the active implementation " + implVersion + " cannot migrate clients"
	}
	if err := m.CheckMigrateClient(clientID, migration, params); err != nil {
		return err.Error()
	}
	return ""
}

// ClientMigrator is implemented by an implementation that can replace the
// verifier of a live client while keeping its id, its consensus states and
// its packet state (ADR pr6375 R16): for an Ethereum client, a new fork
// schedule before a fork, or a conversion to a new light-client package
// version whose containers changed. migration names the conversion and
// params carries its arguments in the wire format it documents.
//
// MigrateClient returns why it refused, with nothing changed, or nil once
// the migration is installed: every failure it can tell before installing
// (a converted verifier failing its checks included) is a refusal, so the
// governed decision is spent rather than left pending.
type ClientMigrator interface {
	MigrateClient(_ int, rlm realm, clientID, migration string, params []byte) error
}

// MigrateClient migrates the verifier of clientID (see ClientMigrator) and
// returns "" once it is installed, or why it was refused, nothing changed.
// Governance only. Panics if the active implementation migrates nothing.
func MigrateClient(cur realm, clientID, migration string, params []byte) string {
	assertGovernance(0, cur, "migrate_client")
	ensureNotRetired(clientID)
	m, ok := mustImpl().(ClientMigrator)
	if !ok {
		panic("core: the active implementation " + implVersion + " cannot migrate clients")
	}
	if err := m.MigrateClient(0, cur, clientID, migration, params); err != nil {
		return err.Error()
	}
	newTrustGeneration(clientID)
	return ""
}

// ClientType returns the type of clientID ("07-tendermint", "ethereum", ...),
// or "" if the client is unknown.
func ClientType(clientID string) string {
	c := store.getClient(clientID)
	if c == nil {
		return ""
	}
	return c.typ
}

// CounterpartyClientID returns the counterparty client id registered for
// clientID, or "" if none (or the client is unknown).
func CounterpartyClientID(clientID string) string {
	c := store.getClient(clientID)
	if c == nil {
		return ""
	}
	return c.counterpartyClientID
}

// PacketCommitment returns a copy of the commitment stored for a packet sent
// on clientID, or nil.
func PacketCommitment(clientID string, sequence uint64) []byte {
	c := store.getClient(clientID)
	if c == nil {
		return nil
	}
	return cloneBytes(c.PacketCommitment(sequence))
}

// PacketReceipt returns a copy of the receipt stored for a packet received on
// clientID (types.CommitPacketReceipt of the packet), or nil.
func PacketReceipt(clientID string, sequence uint64) []byte {
	c := store.getClient(clientID)
	if c == nil {
		return nil
	}
	return cloneBytes(c.PacketReceipt(sequence))
}

// PacketAcknowledgement returns a copy of the acknowledgement commitment
// written for a packet received on clientID, or nil (none yet, or an
// asynchronous acknowledgement still unwritten).
func PacketAcknowledgement(clientID string, sequence uint64) []byte {
	c := store.getClient(clientID)
	if c == nil {
		return nil
	}
	return cloneBytes(c.PacketAcknowledgement(sequence))
}

// ClientLatestTimestamp is the counterparty time (unix seconds) of
// clientID's latest consensus state, and whether it is known: a packet sent
// over the client must time out after it.
func ClientLatestTimestamp(clientID string) (uint64, bool) {
	c := store.getClient(clientID)
	if c == nil {
		return 0, false
	}
	lc := c.LightClient()
	t, err := lc.TimestampAtHeight(lc.LatestHeight())
	if err != nil {
		return 0, false
	}
	return t, true
}

// ClientTimestampAt is the counterparty time (unix seconds) of clientID's
// consensus state at height.
func ClientTimestampAt(clientID string, height types.Height) (uint64, error) {
	c := store.getClient(clientID)
	if c == nil {
		return 0, ufmt.Errorf("client %s not found", clientID)
	}
	return c.LightClient().TimestampAtHeight(height)
}

// valueProver is implemented by a light client that reads a counterparty
// commitment's value from a proof (the Ethereum client).
type valueProver interface {
	ProvenValue(height types.Height, proof any, path types.MerklePath) ([]byte, error)
}

// CounterpartyValue is the value proof establishes for key in clientID's
// counterparty store at height (zero bytes when none is stored), the key
// prefixed with the counterparty's merkle prefix as registered: what a
// reconciliation reads of the destination's receipt and acknowledgement
// (ADR pr6375 §7.12). It changes nothing.
func CounterpartyValue(clientID string, height types.Height, proof any, key []byte) ([]byte, error) {
	c := store.getClient(clientID)
	if c == nil {
		return nil, ufmt.Errorf("client %s not found", clientID)
	}
	// Only a healthy verifier speaks for the counterparty: not frozen,
	// expired or retired (ADR pr6375 §5.4 "Proven outcomes").
	if store.isRetired(clientID) {
		return nil, ufmt.Errorf("client %s is retired", clientID)
	}
	if status := c.LightClient().Status(); status != lightclient.Active {
		return nil, ufmt.Errorf("client %s is %s, not Active", clientID, status)
	}
	vp, ok := c.LightClient().(valueProver)
	if !ok {
		return nil, ufmt.Errorf("client %s cannot read a counterparty value", clientID)
	}
	return vp.ProvenValue(height, proof, types.BuildMerklePath(c.CounterpartyMerklePrefix(), key))
}

// HasPendingAsyncAck reports whether a packet received on clientID waits for
// its asynchronous acknowledgement.
func HasPendingAsyncAck(clientID string, sequence uint64) bool {
	c := store.getClient(clientID)
	return c != nil && c.hasPendingAsyncAck(sequence)
}

// PendingAsyncAck returns a copy of the packet received on clientID that
// waits for its asynchronous acknowledgement, the block height at which it
// was received, and whether one waits.
func PendingAsyncAck(clientID string, sequence uint64) (packet types.Packet, height int64, ok bool) {
	c := store.getClient(clientID)
	if c == nil {
		return types.Packet{}, 0, false
	}
	p, _, found := c.PendingAsyncAck(sequence)
	if !found {
		return types.Packet{}, 0, false
	}
	out := p
	out.Payloads = make([]types.Payload, len(p.Payloads))
	for i, pl := range p.Payloads {
		pl.Value = cloneBytes(pl.Value)
		out.Payloads[i] = pl
	}
	return out, c.pendingAsyncAckHeight(sequence), true
}

func cloneBytes(b []byte) []byte {
	if b == nil {
		return nil
	}
	return append([]byte{}, b...)
}
