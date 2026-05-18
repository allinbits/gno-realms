package e2e

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type validatorUpdate struct {
	PubKey map[string]string
	Power  string
}

func appendTag(buf []byte, fieldNum int, wireType int) []byte {
	tag := (fieldNum << 3) | wireType
	return binary.AppendUvarint(buf, uint64(tag))
}

func appendProtoVarint(buf []byte, fieldNum int, v uint64) []byte {
	if v == 0 {
		return buf
	}
	buf = appendTag(buf, fieldNum, 0)
	return binary.AppendUvarint(buf, v)
}

func appendLengthDelimited(buf []byte, fieldNum int, bz []byte) []byte {
	if len(bz) == 0 {
		return buf
	}
	buf = appendTag(buf, fieldNum, 2)
	buf = binary.AppendUvarint(buf, uint64(len(bz)))
	return append(buf, bz...)
}

func appendAlwaysLengthDelimited(buf []byte, fieldNum int, bz []byte) []byte {
	buf = appendTag(buf, fieldNum, 2)
	buf = binary.AppendUvarint(buf, uint64(len(bz)))
	return append(buf, bz...)
}

func marshalPublicKey(keyType string, keyBytes []byte) []byte {
	var buf []byte
	switch keyType {
	case "ed25519":
		return appendLengthDelimited(buf, 1, keyBytes)
	case "secp256k1":
		return appendLengthDelimited(buf, 2, keyBytes)
	default:
		return nil
	}
}

func marshalValidatorUpdate(keyType string, keyBytes []byte, power int64) []byte {
	var buf []byte
	pubKeyBz := marshalPublicKey(keyType, keyBytes)
	buf = appendAlwaysLengthDelimited(buf, 1, pubKeyBz)
	if power != 0 {
		buf = appendTag(buf, 2, 0)
		buf = binary.AppendUvarint(buf, uint64(power))
	}
	return buf
}

func marshalVSCProtobuf(validators []validatorUpdate, valsetUpdateID uint64) []byte {
	var buf []byte
	for _, vu := range validators {
		var keyType string
		var keyB64 string
		for k, v := range vu.PubKey {
			keyType = k
			keyB64 = v
			break
		}
		keyBytes, _ := base64.StdEncoding.DecodeString(keyB64)
		power, _ := strconv.ParseInt(vu.Power, 10, 64)
		updateBz := marshalValidatorUpdate(keyType, keyBytes, power)
		buf = appendLengthDelimited(buf, 1, updateBz)
	}
	buf = appendProtoVarint(buf, 2, valsetUpdateID)
	return buf
}

func (s *E2ETestSuite) sendVSCPacket(validators []validatorUpdate, valsetUpdateID uint64) {
	vscProto := marshalVSCProtobuf(validators, valsetUpdateID)

	timeout := time.Now().Add(time.Hour).Unix()
	payload := map[string]any{
		"source_port":      "vaasprovider",
		"destination_port": "vaasconsumer",
		"version":          "vaas-v1",
		"encoding":         "application/x-protobuf",
		"value":            base64.StdEncoding.EncodeToString(vscProto),
	}
	msgSendPacket := map[string]any{
		"@type":             "/ibc.core.channel.v2.MsgSendPacket",
		"source_client":     s.atomoneClientID,
		"timeout_timestamp": fmt.Sprint(uint64(timeout)),
		"signer":            s.atomoneGovAddress,
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
		"--gas", "auto", "--gas-adjustment", "1.5",
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
		txOut, txErr, err := dockerExec(qCtx, s.atomoneContainer,
			"atomoned", "q", "tx", submitResult.TxHash,
			"--node", "tcp://localhost:26657",
			"--output", "json",
		)
		if err != nil {
			s.T().Logf("query tx error: %v, stderr: %s", err, txErr)
			return false
		}
		var txResult struct {
			Code   int    `json:"code"`
			RawLog string `json:"raw_log"`
		}
		if err := json.Unmarshal([]byte(strings.TrimSpace(txOut)), &txResult); err != nil {
			s.T().Logf("unmarshal tx error: %v, output: %s", err, txOut[:min(len(txOut), 200)])
			return false
		}
		if txResult.Code != 0 {
			s.T().Logf("submit proposal tx failed (code=%d): %s", txResult.Code, txResult.RawLog)
			return false
		}
		qCtx2, qCancel2 := context.WithTimeout(context.Background(), 10*time.Second)
		defer qCancel2()
		proposalsOut, propErr, err := dockerExec(qCtx2, s.atomoneContainer,
			"atomoned", "q", "gov", "proposals", "--page-limit", "1", "--page-reverse",
			"--node", "tcp://localhost:26657",
			"--output", "json",
		)
		if err != nil {
			s.T().Logf("query proposals error: %v, stderr: %s", err, propErr)
			return false
		}
		var proposals struct {
			Proposals []struct {
				ID string `json:"id"`
			} `json:"proposals"`
		}
		if err := json.Unmarshal([]byte(strings.TrimSpace(proposalsOut)), &proposals); err != nil {
			s.T().Logf("unmarshal proposals error: %v, output: %s", err, proposalsOut[:min(len(proposalsOut), 200)])
			return false
		}
		if len(proposals.Proposals) == 0 {
			s.T().Logf("no proposals found yet (tx confirmed)")
			return false
		}
		proposalID = proposals.Proposals[0].ID
		return true
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

func (s *E2ETestSuite) TestZZIBCVAASProviderToConsumer() {
	r := s.Require()

	validators := []validatorUpdate{
		{PubKey: map[string]string{"ed25519": s.gnoValidatorPubKey}, Power: "500"},
		{PubKey: map[string]string{"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "50"},
	}

	id1 := s.allocValsetUpdateID()
	s.sendVSCPacket(validators, id1)
	s.waitForVAASValsetUpdateID(id1)
	s.waitForVAASMinValidatorCount(len(validators))

	providerClientID, err := queryVAASProviderClientID(s.gnoContainer)
	r.NoError(err, "provider client ID should be set")
	r.Equal(s.atomoneClientID, providerClientID, "provider client ID should match AtomOne client ID")

	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(550), totalPower, "total voting power should be 550")

	allValidators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(allValidators, 2, "should have 2 validators")

	s.T().Logf("VSC packet verified: validators=%d, total_power=%d", len(allValidators), totalPower)
}

func (s *E2ETestSuite) TestZZIBCVAASUpdateExistingValidator() {
	r := s.Require()

	id1 := s.allocValsetUpdateID()
	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": s.gnoValidatorPubKey}, Power: "100"},
	}, id1)
	s.waitForVAASValsetUpdateID(id1)

	s.T().Log("Initial valset applied, sending update")

	id2 := s.allocValsetUpdateID()
	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": s.gnoValidatorPubKey}, Power: "200"},
	}, id2)
	s.waitForVAASValsetUpdateID(id2)

	validators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators")
	r.Len(validators, 1, "should still have 1 validator")
	r.Equal("ed25519:"+s.gnoValidatorPubKey, validators[0].PubKey)
	r.Equal(int64(200), validators[0].Power, "validator power should be updated to 200")

	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(200), totalPower, "total voting power should be 200")

	s.T().Logf("Validator update verified: pubkey=%s, power=%d", validators[0].PubKey, totalPower)
}

func (s *E2ETestSuite) TestZZIBCVAASRemoveValidator() {
	r := s.Require()

	id1 := s.allocValsetUpdateID()
	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": s.gnoValidatorPubKey}, Power: "500"},
		{PubKey: map[string]string{"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "50"},
	}, id1)
	s.waitForVAASMinValidatorCount(2)

	s.T().Log("Initial validators established, removing one")

	id2 := s.allocValsetUpdateID()
	s.sendVSCPacket([]validatorUpdate{
		{PubKey: map[string]string{"ed25519": "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}, Power: "0"},
	}, id2)
	s.waitForVAASValsetUpdateID(id2)

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
	r.Equal("ed25519:"+s.gnoValidatorPubKey, validators[0].PubKey)
	r.Equal(int64(500), validators[0].Power, "remaining validator power should be 500")

	totalPower, err := queryVAASTotalVotingPower(s.gnoContainer)
	r.NoError(err, "query total voting power")
	r.Equal(int64(500), totalPower, "total voting power should be 500")

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
