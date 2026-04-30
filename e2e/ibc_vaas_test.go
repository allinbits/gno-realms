package e2e

import (
	"encoding/json"
	"fmt"
	"time"

	channeltypesv2 "github.com/cosmos/ibc-go/v10/modules/core/04-channel/v2/types"
)

// validatorUpdate represents a validator update in VSC packet data.
type validatorUpdate struct {
	PubKey map[string]string `json:"pub_key"`
	Power  string            `json:"power"`
}

// vscPacketData represents the VSC packet data structure.
type vscPacketData struct {
	ValidatorUpdates []validatorUpdate `json:"validator_updates"`
	ValsetUpdateID   string            `json:"valset_update_id"`
}

func (s *E2ETestSuite) sendVSCPacket(validators []validatorUpdate, valsetUpdateID uint64) {
	vscData := vscPacketData{
		ValidatorUpdates: validators,
		ValsetUpdateID:   fmt.Sprint(valsetUpdateID),
	}
	vscJSON, err := json.Marshal(vscData)
	s.Require().NoError(err, "marshal VSC packet data")

	msg := buildMsgSendPacketVAAS(
		s.atomoneClientID, s.atomOneSenderAddress,
		"provider", "consumer",
		vscJSON, time.Now().Add(time.Hour).Unix(),
	)
	s.signAndBroadcastAtomOneTx(s.atomOneSenderAddress, msg)
	s.T().Logf("VSC packet submitted: valset_update_id=%d, validators=%d", valsetUpdateID, len(validators))
}

func (s *E2ETestSuite) waitForVAASValsetUpdateID(expected uint64) {
	s.waitForCondition(2*time.Minute, 3*time.Second, func() bool {
		id, err := queryVAASHighestValsetUpdateID(s.gnoContainer)
		if err != nil {
			return false
		}
		return id >= expected
	}, fmt.Sprintf("valset update ID >= %d not received on Gno", expected))
}

func (s *E2ETestSuite) waitForVAASMinValidatorCount(expected int) {
	s.waitForCondition(30*time.Second, 2*time.Second, func() bool {
		count, err := queryVAASValidatorCount(s.gnoContainer)
		if err != nil {
			return false
		}
		return count >= expected
	}, fmt.Sprintf("validator count >= %d not reached on Gno", expected))
}

func (s *E2ETestSuite) TestIBCVAASProviderToConsumer() {
	r := s.Require()

	validators := []validatorUpdate{
		{PubKey: map[string]string{"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "100"},
		{PubKey: map[string]string{"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "50"},
	}

	s.sendVSCPacket(validators, 1)
	s.waitForVAASValsetUpdateID(1)
	s.waitForVAASMinValidatorCount(len(validators))

	// Verify provider client ID is set
	providerClientID, hasProvider := queryVAASProviderClientID(s.gnoContainer)
	r.True(hasProvider, "provider client ID should be set")
	r.Equal(s.gnoClientID, providerClientID, "provider client ID should match Gno client ID")

	// Verify total voting power
	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(150), totalPower, "total voting power should be 150")

	allValidators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(allValidators, 2, "should have 2 validators")

	s.T().Logf("VSC packet verified: validators=%d, total_power=%d", len(allValidators), totalPower)
}

func (s *E2ETestSuite) TestIBCVAASUpdateExistingValidator() {
	r := s.Require()

	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "100"},
	}, 1)
	s.waitForVAASValsetUpdateID(1)

	s.T().Log("Initial valset applied, sending update")

	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "200"},
	}, 2)
	s.waitForVAASValsetUpdateID(2)

	validators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(validators, 1, "should still have 1 validator")
	r.Equal("ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=", validators[0].PubKey)
	r.Equal(int64(200), validators[0].Power, "validator power should be updated to 200")

	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(200), totalPower, "total voting power should be 200")

	s.T().Logf("Validator update verified: pubkey=%s, power=%d", validators[0].PubKey, totalPower)
}

func (s *E2ETestSuite) TestIBCVAASRemoveValidator() {
	r := s.Require()

	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "100"},
		{PubKey: map[string]string{"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "50"},
	}, 1)
	s.waitForVAASMinValidatorCount(2)

	s.T().Log("Initial validators established, removing one")

	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "0"},
	}, 2)
	s.waitForVAASValsetUpdateID(2)

	r.Eventually(func() bool {
		count, err := queryVAASValidatorCount(s.gnoContainer)
		if err != nil {
			return false
		}
		return count == 1
	}, 30*time.Second, 2*time.Second, "validator count did not decrease to 1")

	validators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(validators, 1, "should have 1 validator remaining")
	r.Equal("ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=", validators[0].PubKey)
	r.Equal(int64(100), validators[0].Power, "remaining validator power should be 100")

	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(100), totalPower, "total voting power should be 100")

	s.T().Logf("Validator removal verified: validators=%d, total_power=%d", len(validators), totalPower)
}

func buildMsgSendPacketVAAS(
	sourceClient, sender string,
	sourcePort, destinationPort string,
	packetData []byte,
	timeoutTimestamp int64,
) *channeltypesv2.MsgSendPacket {
	payload := channeltypesv2.NewPayload(
		sourcePort, destinationPort,
		"1",                // Version
		"application/json", // Encoding
		packetData,
	)
	return channeltypesv2.NewMsgSendPacket(
		sourceClient, uint64(timeoutTimestamp), sender, payload,
	)
}
