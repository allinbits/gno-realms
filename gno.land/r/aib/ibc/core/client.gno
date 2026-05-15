package core

import (
	"chain"
	"chain/runtime"

	"gno.land/p/aib/ibc/host"
	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt/v0"
)

// CreateClient generates a new client identifier and invokes the associated
// light client module in order to initialize the client.
func CreateClient(cur realm, clientState lightclient.ClientState, consensusState lightclient.ConsensusState) string {
	if clientState.ClientType() != consensusState.ClientType() {
		panic("client type for client state and consensus state do not match")
	}
	if err := types.ValidateClientType(clientState.ClientType()); err != nil {
		panic(ufmt.Sprintf(
			"client type does not meet naming constraints: %v", err,
		))
	}

	if err := clientState.ValidateBasic(); err != nil {
		panic(err)
	}
	if err := consensusState.ValidateBasic(); err != nil {
		panic(err)
	}
	ensureAuthorizedRelayer()
	c := store.addClient(clientState.ClientType(), runtime.OriginCaller())
	err := c.lightClient.Initialize(clientState, consensusState)
	if err != nil {
		panic(err)
	}
	if status := c.lightClient.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("cannot create client (%s) with status %s", c.id, status))
	}
	// Emit create client event
	chain.Emit(types.EventTypeCreateClient,
		types.AttributeKeyClientID, c.id,
		types.AttributeKeyClientType, c.typ,
		types.AttributeKeyConsensusHeights, c.lightClient.LatestHeight().String(),
	)
	return c.id
}

// RegisterCounterparty will register the IBC v2 counterparty info for the
// given clientID. It must be called by the same relayer that called
// CreateClient.
func RegisterCounterparty(cur realm, clientID string, counterpartyMerklePrefix [][]byte, counterpartyClientID string) {
	if !types.IsValidClientID(counterpartyClientID) {
		panic("invalid counterparty client id")
	}
	c := store.getClient(clientID)
	if c == nil {
		panic(ufmt.Sprintf("client %s not found", clientID))
	}
	if c.creator != runtime.OriginCaller() {
		panic(ufmt.Sprintf("expected same signer as CreateClient submitter %s, got %s", c.creator, runtime.OriginCaller()))
	}
	if c.counterpartyClientID != "" {
		panic("cannot register counterparty once it is already set")
	}
	c.counterpartyClientID = counterpartyClientID
	c.counterpartyMerklePrefix = counterpartyMerklePrefix
}

// UpdateClient will update the given IBC v2 light client with a new header.
// Can also be used to submit a misbehavior (clientMessage can be a header or
// a misbehavior, maybe split into 2 functions would make more sense here).
func UpdateClient(cur realm, clientID string, clientMessage lightclient.ClientMessage) {
	if err := clientMessage.ValidateBasic(); err != nil {
		panic(err)
	}
	c := store.getClient(clientID)
	if c == nil {
		panic(ufmt.Sprintf("client %s not found", clientID))
	}
	ensureAuthorizedRelayer()
	if c.typ != clientMessage.ClientType() {
		panic("client type for client state and client message do not match")
	}
	if status := c.lightClient.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("cannot update client (%s) with status %s", c.id, status))
	}

	err := c.lightClient.VerifyClientMessage(clientMessage)
	if err != nil {
		panic(err)
	}

	foundMisbehavior := c.lightClient.CheckForMisbehaviour(clientMessage)
	if foundMisbehavior {
		c.lightClient.UpdateStateOnMisbehaviour(clientMessage)

		chain.Emit(types.EventTypeSubmitMisbehaviour,
			types.AttributeKeyClientID, c.id,
			types.AttributeKeyClientType, c.typ,
		)
		return
	}

	consensusHeights := c.lightClient.UpdateState(clientMessage)

	// Emit update client event
	var consensusHeightsStr string
	for i, h := range consensusHeights {
		consensusHeightsStr += h.String()
		if i < len(consensusHeights)-1 {
			consensusHeightsStr += ", "
		}
	}
	chain.Emit(types.EventTypeUpdateClient,
		types.AttributeKeyClientID, c.id,
		types.AttributeKeyClientType, c.typ,
		types.AttributeKeyConsensusHeights, consensusHeightsStr,
	)
}

// UpgradeClient upgrades the client to a new client and consensus state,
// verified by proofs that the counterparty chain committed to those states
// at its UpgradePath under the current client's latest consensus root.
func UpgradeClient(cur realm, clientID string, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState any) {
	if err := host.ClientIdentifierValidator(clientID); err != nil {
		panic(err)
	}
	ensureAuthorizedRelayer()
	c := store.getClient(clientID)
	if c == nil {
		panic(ufmt.Sprintf("client %s not found", clientID))
	}
	if status := c.lightClient.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("cannot upgrade client (%s) with status %s", c.id, status))
	}
	if err := c.lightClient.VerifyUpgradeAndUpdateState(clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState); err != nil {
		panic(err)
	}
	chain.Emit(types.EventTypeUpgradeClient,
		types.AttributeKeyClientID, c.id,
		types.AttributeKeyClientType, c.typ,
		types.AttributeKeyConsensusHeight, c.lightClient.LatestHeight().String(),
	)
}

// RecoverClient recovers a frozen or expired subject client using a healthy
// substitute client that tracks the same counterparty chain.
func RecoverClient(cur realm, subjectClientID, substituteClientID string) {
	ensureAdminCaller()
	if subjectClientID == substituteClientID {
		panic("subject and substitute client IDs must differ")
	}
	subject := store.getClient(subjectClientID)
	if subject == nil {
		panic(ufmt.Sprintf("subject client %s not found", subjectClientID))
	}
	substitute := store.getClient(substituteClientID)
	if substitute == nil {
		panic(ufmt.Sprintf("substitute client %s not found", substituteClientID))
	}
	if subject.typ != substitute.typ {
		panic(ufmt.Sprintf(
			"subject client type %s does not match substitute client type %s",
			subject.typ, substitute.typ,
		))
	}
	if status := subject.lightClient.Status(); status != lightclient.Frozen && status != lightclient.Expired {
		panic(ufmt.Sprintf(
			"cannot recover subject client %s with status %s",
			subject.id, status,
		))
	}
	if status := substitute.lightClient.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf(
			"substitute client %s must be Active, got %s",
			substitute.id, status,
		))
	}
	if err := subject.lightClient.RecoverClient(substitute.lightClient); err != nil {
		panic(err)
	}
	chain.Emit(types.EventTypeRecoverClient,
		types.AttributeKeySubjectClientID, subject.id,
		types.AttributeKeySubstituteClientID, substitute.id,
		types.AttributeKeyClientType, subject.typ,
	)
}
