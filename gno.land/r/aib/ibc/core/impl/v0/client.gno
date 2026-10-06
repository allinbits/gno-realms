package impl

import (
	"chain/runtime/unsafe"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/lightclient/tendermint/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
)

func (l *logic) mustClient(clientID string) core.Client {
	c := l.store.Client(clientID)
	if c == nil {
		panic(ufmt.Sprintf("client %s not found", clientID))
	}
	return c
}

// CreateClient initializes the light client of the given type with the
// states and records relayer as its creator.
func (l *logic) CreateClient(_ int, rlm realm, relayer address, clientState lightclient.ClientState, consensusState lightclient.ConsensusState) string {
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
	var newLightClient func() lightclient.Interface
	switch typ := clientState.ClientType(); typ {
	case lightclient.Tendermint:
		newLightClient = tendermint.NewLightClient
	default:
		panic("unhandled light client type " + typ)
	}
	c := l.store.AddClient(0, rlm, clientState.ClientType(), relayer, newLightClient)
	lc := c.LightClient()
	err := lc.Initialize(clientState, consensusState)
	if err != nil {
		panic(err)
	}
	if status := lc.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("cannot create client (%s) with status %s", c.ID(), status))
	}
	core.EmitCreateClient(0, rlm, c.ID(), c.Type(), lc.LatestHeight().String())
	return c.ID()
}

// RegisterCounterparty registers the IBC v2 counterparty info for the given
// clientID. It must be called by the same relayer that called CreateClient.
func (l *logic) RegisterCounterparty(_ int, rlm realm, clientID string, counterpartyMerklePrefix [][]byte, counterpartyClientID string) {
	if !types.IsValidClientID(counterpartyClientID) {
		panic("invalid counterparty client id")
	}
	c := l.mustClient(clientID)
	caller := unsafe.OriginCaller()
	if c.Creator() != caller {
		panic(ufmt.Sprintf("expected same signer as CreateClient submitter %s, got %s", c.Creator(), caller))
	}
	if c.CounterpartyClientID() != "" {
		panic("cannot register counterparty once it is already set")
	}
	c.SetCounterparty(0, rlm, counterpartyClientID, counterpartyMerklePrefix)
}

// UpdateClient updates the given light client with a new header, or submits a
// misbehaviour (clientMessage can be either).
func (l *logic) UpdateClient(_ int, rlm realm, clientID string, clientMessage lightclient.ClientMessage) {
	if err := clientMessage.ValidateBasic(); err != nil {
		panic(err)
	}
	c := l.mustClient(clientID)
	if c.Type() != clientMessage.ClientType() {
		panic("client type for client state and client message do not match")
	}
	lc := c.LightClient()
	if status := lc.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("cannot update client (%s) with status %s", c.ID(), status))
	}

	err := lc.VerifyClientMessage(clientMessage)
	if err != nil {
		panic(err)
	}

	foundMisbehavior := lc.CheckForMisbehaviour(clientMessage)
	if foundMisbehavior {
		lc.UpdateStateOnMisbehaviour(clientMessage)
		core.EmitSubmitMisbehaviour(0, rlm, c.ID(), c.Type())
		return
	}

	consensusHeights := lc.UpdateState(clientMessage)

	var consensusHeightsStr string
	for i, h := range consensusHeights {
		consensusHeightsStr += h.String()
		if i < len(consensusHeights)-1 {
			consensusHeightsStr += ", "
		}
	}
	core.EmitUpdateClient(0, rlm, c.ID(), c.Type(), consensusHeightsStr)
}

// UpgradeClient upgrades the client to a new client and consensus state,
// verified by proofs that the counterparty chain committed to those states
// at its UpgradePath under the current client's latest consensus root.
func (l *logic) UpgradeClient(_ int, rlm realm, clientID string, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState any) {
	if err := host.ClientIdentifierValidator(clientID); err != nil {
		panic(err)
	}
	c := l.mustClient(clientID)
	lc := c.LightClient()
	if status := lc.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("cannot upgrade client (%s) with status %s", c.ID(), status))
	}
	if err := lc.VerifyUpgradeAndUpdateState(clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState); err != nil {
		panic(err)
	}
	core.EmitUpgradeClient(0, rlm, c.ID(), c.Type(), lc.LatestHeight().String())
}

// RecoverClient recovers a frozen or expired subject client using a healthy
// substitute client that tracks the same counterparty chain.
func (l *logic) RecoverClient(_ int, rlm realm, subjectClientID, substituteClientID string) {
	if subjectClientID == substituteClientID {
		panic("subject and substitute client IDs must differ")
	}
	subject := l.store.Client(subjectClientID)
	if subject == nil {
		panic(ufmt.Sprintf("subject client %s not found", subjectClientID))
	}
	substitute := l.store.Client(substituteClientID)
	if substitute == nil {
		panic(ufmt.Sprintf("substitute client %s not found", substituteClientID))
	}
	if subject.Type() != substitute.Type() {
		panic(ufmt.Sprintf(
			"subject client type %s does not match substitute client type %s",
			subject.Type(), substitute.Type(),
		))
	}
	if status := subject.LightClient().Status(); status != lightclient.Frozen && status != lightclient.Expired {
		panic(ufmt.Sprintf(
			"cannot recover subject client %s with status %s",
			subject.ID(), status,
		))
	}
	if status := substitute.LightClient().Status(); status != lightclient.Active {
		panic(ufmt.Sprintf(
			"substitute client %s must be Active, got %s",
			substitute.ID(), status,
		))
	}
	if err := subject.LightClient().RecoverClient(substitute.LightClient()); err != nil {
		panic(err)
	}
	core.EmitRecoverClient(0, rlm, subject.ID(), substitute.ID(), subject.Type())
}
