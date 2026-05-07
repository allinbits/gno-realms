package e2e

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type validatorUpdate struct {
	PubKey map[string]string `json:"pub_key"`
	Power  string            `json:"power"`
}

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

	timeout := time.Now().Add(time.Hour).Unix()
	payload := map[string]any{
		"source_port":      "vaasprovider",
		"destination_port": "vaasconsumer",
		"version":          "1",
		"encoding":         "application/json",
		"value":            base64.StdEncoding.EncodeToString(vscJSON),
	}
	msgSendPacket := map[string]any{
		"@type":             "/ibc.core.channel.v2.MsgSendPacket",
		"source_client":     s.atomoneClientID,
		"timeout_timestamp": fmt.Sprint(uint64(timeout)),
		"signer":            s.atomOneSenderAddress,
		"payloads":          []any{payload},
	}
	proposal := map[string]any{
		"messages":  []any{msgSendPacket},
		"metadata":  "",
		"deposit":   "1uatone",
		"title":     fmt.Sprintf("VSC packet %d", valsetUpdateID),
		"summary":   fmt.Sprintf("Send VSC packet with valset_update_id=%d", valsetUpdateID),
		"expedited": true,
	}
	proposalJSON, err := json.Marshal(proposal)
	s.Require().NoError(err, "marshal proposal JSON")

	ctx := context.Background()

	_, stderr, err := dockerExecStdin(ctx, s.atomoneContainer, string(proposalJSON),
		"bash", "-c", "cat > /tmp/vsc_proposal.json")
	s.Require().NoError(err, "write proposal file: %s", stderr)

	submitCtx, submitCancel := context.WithTimeout(ctx, 30*time.Second)
	defer submitCancel()
	stdout, stderr, err := dockerExec(submitCtx, s.atomoneContainer,
		"atomoned", "tx", "gov", "submit-proposal", "/tmp/vsc_proposal.json",
		"--from", s.atomOneSenderAddress,
		"--chain-id", s.cfg.AtomoneChainID,
		"--keyring-backend", "test",
		"--home", "/root/.atomone",
		"--node", "tcp://localhost:26657",
		"--gas-prices", "0.025uphoton",
		"--yes", "--output", "json",
	)
	s.Require().NoError(err, "submit proposal: %s", stderr)

	var submitResult struct {
		TxHash string `json:"txhash"`
		Code   int    `json:"code"`
		RawLog string `json:"raw_log"`
	}
	s.Require().NoError(json.Unmarshal([]byte(strings.TrimSpace(stdout)), &submitResult))
	s.Require().Equal(0, submitResult.Code, "submit proposal tx failed: %s", submitResult.RawLog)
	s.Require().NotEmpty(submitResult.TxHash)

	var proposalID string
	s.Require().Eventually(func() bool {
		qCtx, qCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer qCancel()
		txOut, _, err := dockerExec(qCtx, s.atomoneContainer,
			"atomoned", "q", "tx", submitResult.TxHash,
			"--node", "tcp://localhost:26657",
			"--output", "json",
		)
		if err != nil {
			return false
		}
		var txResult struct {
			Code int `json:"code"`
			Logs []struct {
				Events []struct {
					Type  string `json:"type"`
					Attrs []struct {
						Key   string `json:"key"`
						Value string `json:"value"`
					} `json:"attributes"`
				} `json:"events"`
			} `json:"logs"`
		}
		if err := json.Unmarshal([]byte(strings.TrimSpace(txOut)), &txResult); err != nil {
			return false
		}
		if txResult.Code != 0 {
			return false
		}
		for _, log := range txResult.Logs {
			for _, ev := range log.Events {
				if ev.Type == "submit_proposal" {
					for _, attr := range ev.Attrs {
						if attr.Key == "proposal_id" {
							proposalID = attr.Value
							return true
						}
					}
				}
			}
		}
		return false
	}, 15*time.Second, time.Second, "proposal_id not found for tx %s", submitResult.TxHash)

	s.T().Logf("Proposal %s submitted", proposalID)

	voteCtx, voteCancel := context.WithTimeout(ctx, 30*time.Second)
	defer voteCancel()
	stdout, stderr, err = dockerExec(voteCtx, s.atomoneContainer,
		"atomoned", "tx", "gov", "vote", proposalID, "yes",
		"--from", s.atomOneSenderAddress,
		"--chain-id", s.cfg.AtomoneChainID,
		"--keyring-backend", "test",
		"--home", "/root/.atomone",
		"--node", "tcp://localhost:26657",
		"--gas-prices", "0.025uphoton",
		"--yes", "--output", "json",
	)
	s.Require().NoError(err, "vote on proposal: %s", stderr)

	var voteResult struct {
		TxHash string `json:"txhash"`
		Code   int    `json:"code"`
		RawLog string `json:"raw_log"`
	}
	s.Require().NoError(json.Unmarshal([]byte(strings.TrimSpace(stdout)), &voteResult))
	s.Require().Equal(0, voteResult.Code, "vote tx failed: %s", voteResult.RawLog)

	s.Require().Eventually(func() bool {
		qCtx, qCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer qCancel()
		txOut, _, err := dockerExec(qCtx, s.atomoneContainer,
			"atomoned", "q", "tx", voteResult.TxHash,
			"--node", "tcp://localhost:26657",
			"--output", "json",
		)
		if err != nil {
			return false
		}
		var txResult struct {
			Code int `json:"code"`
		}
		if err := json.Unmarshal([]byte(strings.TrimSpace(txOut)), &txResult); err != nil {
			return false
		}
		return txResult.Code == 0
	}, 15*time.Second, time.Second, "vote tx %s not confirmed", voteResult.TxHash)

	s.T().Logf("Voted YES on proposal %s", proposalID)

	s.waitForGovProposalPassed(proposalID)
	s.T().Logf("VSC packet proposal %s executed: valset_update_id=%d, validators=%d", proposalID, valsetUpdateID, len(validators))
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

func (s *E2ETestSuite) waitForGovProposalPassed(proposalID string) {
	id, err := strconv.ParseUint(proposalID, 10, 64)
	s.Require().NoError(err, "parse proposal ID")

	s.waitForCondition(1*time.Minute, 2*time.Second, func() bool {
		status, err := queryGovProposalStatus(s.cfg.AtomoneREST, id)
		if err != nil {
			return false
		}
		return status == "PROPOSAL_STATUS_PASSED" || status == "PROPOSAL_STATUS_EXECUTED"
	}, fmt.Sprintf("gov proposal %s not passed", proposalID))
}
