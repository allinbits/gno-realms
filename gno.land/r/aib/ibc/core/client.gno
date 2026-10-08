package core

import (
	"gno.land/p/aib/ibc/lightclient/v0"
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
	mustImpl().RegisterCounterparty(0, cur, clientID, counterpartyMerklePrefix, counterpartyClientID)
}

// UpdateClient will update the given IBC v2 light client with a new header.
// Can also be used to submit a misbehavior (clientMessage can be a header or
// a misbehavior). Relayers only.
func UpdateClient(cur realm, clientID string, clientMessage lightclient.ClientMessage) {
	ensureAuthorizedRelayer()
	mustImpl().UpdateClient(0, cur, clientID, clientMessage)
}

// UpgradeClient upgrades the client to a new client and consensus state,
// verified by proofs that the counterparty chain committed to those states
// at its UpgradePath under the current client's latest consensus root.
// Relayers only.
func UpgradeClient(cur realm, clientID string, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState any) {
	ensureAuthorizedRelayer()
	mustImpl().UpgradeClient(0, cur, clientID, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState)
}

// RecoverClient recovers a frozen or expired subject client using a healthy
// substitute client that tracks the same counterparty chain. Authority
// members only; see proposals.gno for the GovDAO path.
func RecoverClient(cur realm, subjectClientID, substituteClientID string) {
	recoverClient(0, cur, subjectClientID, substituteClientID)
}

func recoverClient(_ int, rlm realm, subjectClientID, substituteClientID string) {
	auth.Assert(0, rlm, "recover_client")
	mustImpl().RecoverClient(0, rlm, subjectClientID, substituteClientID)
}
