package e2e

import (
	"encoding/json"
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

func (s *E2ETestSuite) TestIBCVAASProviderToConsumer() {
	r := s.Require()

	// Define validator updates to send
	valsetUpdateID := uint64(1)
	validatorUpdates := []validatorUpdate{
		{
			PubKey: map[string]string{
				"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=",
			},
			Power: "100",
		},
		{
			PubKey: map[string]string{
				"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=",
			},
			Power: "50",
		},
	}

	// Build VSC packet data
	vscPacketData := vscPacketData{
		ValidatorUpdates: validatorUpdates,
		ValsetUpdateID:   "1",
	}

	vscJSON, err := json.Marshal(vscPacketData)
	r.NoError(err, "marshal VSC packet data")

	s.T().Logf("Broadcasting VSC packet: valset_update_id=%d, validators=%d", valsetUpdateID, len(validatorUpdates))

	// Build and broadcast MsgSendPacket with VSC data
	msg := buildMsgSendPacketVAAS(
		s.atomoneClientID, s.senderAddress,
		"provider", "consumer",
		vscJSON, time.Now().Add(time.Hour).Unix(),
	)

	txHash := s.signAndBroadcastAtomOneTx(msg)
	s.T().Logf("VSC packet submitted: txhash=%s", txHash)

	// Query VAAS consumer state before relay
	s.T().Log("Querying VAAS consumer state before relay...")
	beforeValsetID, _ := queryVAASHighestValsetUpdateID(s.gnoContainer)
	beforeValidatorCount, _ := queryVAASValidatorCount(s.gnoContainer)
	s.T().Logf("Before relay - ValsetUpdateID: %d, Validators: %d", beforeValsetID, beforeValidatorCount)

	// Wait for valset update ID to be incremented on Gno
	s.T().Log("Waiting for valset update ID on Gno...")
	r.Eventually(func() bool {
		valsetID, err := queryVAASHighestValsetUpdateID(s.gnoContainer)
		if err != nil {
			return false
		}
		return valsetID >= valsetUpdateID
	}, 2*time.Minute, 3*time.Second, "valset update ID not received on Gno")

	// Verify validator count increased
	s.T().Log("Verifying validator count increased on Gno...")
	r.Eventually(func() bool {
		count, err := queryVAASValidatorCount(s.gnoContainer)
		if err != nil {
			return false
		}
		return count >= len(validatorUpdates)
	}, 30*time.Second, 2*time.Second, "validator count did not increase on Gno")

	// Verify provider client ID is set
	providerClientID, hasProvider := queryVAASProviderClientID(s.gnoContainer)
	r.True(hasProvider, "provider client ID should be set")
	r.Equal(s.gnoClientID, providerClientID, "provider client ID should match Gno client ID")

	// Verify total voting power
	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	expectedPower := int64(150) // 100 + 50
	r.Equal(expectedPower, totalPower, "total voting power should be 150")

	// Verify validators are correctly stored
	validators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(validators, 2, "should have 2 validators")

	s.T().Logf("VSC packet verified: valset_update_id=%d, validators=%d, total_power=%d",
		valsetUpdateID, len(validators), totalPower)
}

func (s *E2ETestSuite) TestIBCVAASUpdateExistingValidator() {
	r := s.Require()

	// First, send initial VSC packet to establish validators
	valsetUpdateID1 := uint64(1)
	validatorUpdates1 := []validatorUpdate{
		{
			PubKey: map[string]string{
				"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=",
			},
			Power: "100",
		},
	}

	vscPacketData1 := vscPacketData{
		ValidatorUpdates: validatorUpdates1,
		ValsetUpdateID:   "1",
	}

	vscJSON1, err := json.Marshal(vscPacketData1)
	r.NoError(err, "marshal initial VSC packet data")

	msg1 := buildMsgSendPacketVAAS(
		s.atomoneClientID, s.senderAddress,
		"provider", "consumer",
		vscJSON1, time.Now().Add(time.Hour).Unix(),
	)

	s.signAndBroadcastAtomOneTx(msg1)
	s.T().Logf("Initial VSC packet submitted: valset_update_id=%d", valsetUpdateID1)

	// Wait for first valset update to be applied
	r.Eventually(func() bool {
		valsetID, err := queryVAASHighestValsetUpdateID(s.gnoContainer)
		if err != nil {
			return false
		}
		return valsetID >= valsetUpdateID1
	}, 2*time.Minute, 3*time.Second, "first valset update not received")

	s.T().Log("First valset update applied, now sending update")

	// Send second VSC packet to update validator power
	valsetUpdateID2 := uint64(2)
	validatorUpdates2 := []validatorUpdate{
		{
			PubKey: map[string]string{
				"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=",
			},
			Power: "200", // Update from 100 to 200
		},
	}

	vscPacketData2 := vscPacketData{
		ValidatorUpdates: validatorUpdates2,
		ValsetUpdateID:   "2",
	}

	vscJSON2, err := json.Marshal(vscPacketData2)
	r.NoError(err, "marshal update VSC packet data")

	msg2 := buildMsgSendPacketVAAS(
		s.atomoneClientID, s.senderAddress,
		"provider", "consumer",
		vscJSON2, time.Now().Add(time.Hour).Unix(),
	)

	txHash := s.signAndBroadcastAtomOneTx(msg2)
	s.T().Logf("Update VSC packet submitted: txhash=%s, valset_update_id=%d", txHash, valsetUpdateID2)

	// Wait for second valset update to be applied
	s.T().Log("Waiting for valset update ID to increment...")
	r.Eventually(func() bool {
		valsetID, err := queryVAASHighestValsetUpdateID(s.gnoContainer)
		if err != nil {
			return false
		}
		return valsetID >= valsetUpdateID2
	}, 2*time.Minute, 3*time.Second, "second valset update not received")

	// Verify validator power was updated
	validators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(validators, 1, "should still have 1 validator")

	expectedPubKey := "ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="
	r.Equal(expectedPubKey, validators[0].PubKey, "pubkey should match")
	r.Equal(int64(200), validators[0].Power, "validator power should be updated to 200")

	// Verify total voting power
	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(200), totalPower, "total voting power should be 200")

	s.T().Logf("Validator update verified: pubkey=%s, power=%d", expectedPubKey, totalPower)
}

func (s *E2ETestSuite) TestIBCVAASRemoveValidator() {
	r := s.Require()

	// First, establish validators
	validatorUpdates1 := []validatorUpdate{
		{
			PubKey: map[string]string{
				"ed25519": "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=",
			},
			Power: "100",
		},
		{
			PubKey: map[string]string{
				"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=",
			},
			Power: "50",
		},
	}

	vscPacketData1 := vscPacketData{
		ValidatorUpdates: validatorUpdates1,
		ValsetUpdateID:   "1",
	}

	vscJSON1, err := json.Marshal(vscPacketData1)
	r.NoError(err, "marshal initial VSC packet data")

	msg1 := buildMsgSendPacketVAAS(
		s.atomoneClientID, s.senderAddress,
		"provider", "consumer",
		vscJSON1, time.Now().Add(time.Hour).Unix(),
	)

	s.signAndBroadcastAtomOneTx(msg1)

	// Wait for initial validators to be established
	r.Eventually(func() bool {
		count, err := queryVAASValidatorCount(s.gnoContainer)
		if err != nil {
			return false
		}
		return count >= 2
	}, 2*time.Minute, 3*time.Second, "initial validators not established")

	s.T().Log("Initial validators established, now removing one")

	// Send VSC packet to remove a validator (power = 0)
	valsetUpdateID2 := uint64(2)
	validatorUpdates2 := []validatorUpdate{
		{
			PubKey: map[string]string{
				"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=",
			},
			Power: "0", // Remove validator
		},
	}

	vscPacketData2 := vscPacketData{
		ValidatorUpdates: validatorUpdates2,
		ValsetUpdateID:   "2",
	}

	vscJSON2, err := json.Marshal(vscPacketData2)
	r.NoError(err, "marshal removal VSC packet data")

	msg2 := buildMsgSendPacketVAAS(
		s.atomoneClientID, s.senderAddress,
		"provider", "consumer",
		vscJSON2, time.Now().Add(time.Hour).Unix(),
	)

	txHash := s.signAndBroadcastAtomOneTx(msg2)
	s.T().Logf("Removal VSC packet submitted: txhash=%s, valset_update_id=%d", txHash, valsetUpdateID2)

	// Wait for second valset update to be applied
	r.Eventually(func() bool {
		valsetID, err := queryVAASHighestValsetUpdateID(s.gnoContainer)
		if err != nil {
			return false
		}
		return valsetID >= valsetUpdateID2
	}, 2*time.Minute, 3*time.Second, "valset update not received")

	// Verify validator count decreased
	s.T().Log("Verifying validator count decreased...")
	r.Eventually(func() bool {
		count, err := queryVAASValidatorCount(s.gnoContainer)
		if err != nil {
			return false
		}
		return count == 1
	}, 30*time.Second, 2*time.Second, "validator count did not decrease")

	// Verify correct validator remains
	validators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(validators, 1, "should have 1 validator remaining")

	expectedPubKey := "ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="
	r.Equal(expectedPubKey, validators[0].PubKey, "remaining validator pubkey should match")
	r.Equal(int64(100), validators[0].Power, "remaining validator power should be 100")

	// Verify total voting power
	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(100), totalPower, "total voting power should be 100")

	s.T().Logf("Validator removal verified: validators=%d, total_power=%d", len(validators), totalPower)
}

// buildMsgSendPacketVAAS creates a MsgSendPacket for a VAAS VSC packet.
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
