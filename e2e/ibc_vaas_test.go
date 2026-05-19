package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// TestZZIBCVAASRealVSCFlow tests the real VAAS provider VSC flow:
// register consumer → delegate tokens on AtomOne → epoch boundary →
// provider sends VSC packet → relayer relays to Gno →
// Gno consumer receives and applies validator set changes.
func (s *E2ETestSuite) TestZZIBCVAASRealVSCFlow() {
	r := s.Require()

	s.createConsumerOnProvider()

	valOperAddr := s.getValidatorOperatorAddress()
	s.T().Logf("Validator operator address: %s", valOperAddr)

	initialPower := s.getProviderValidatorVotingPower()
	s.T().Logf("Initial validator voting power: %d", initialPower)

	s.delegateTokens(valOperAddr)

	var newPower uint64
	r.Eventually(func() bool {
		newPower = s.getProviderValidatorVotingPower()
		return newPower > initialPower
	}, 30*time.Second, time.Second, "validator voting power did not increase after delegation")
	s.T().Logf("Validator voting power increased: %d -> %d", initialPower, newPower)

	s.T().Log("Waiting for VSC packet to reach Gno consumer (epoch boundary + relay)...")
	s.waitForCondition(3*time.Minute, 3*time.Second, func() bool {
		count, err := queryVAASValidatorCount(s.gnoContainer)
		if err != nil {
			return false
		}
		return count >= 1
	}, "Gno consumer did not receive validators from provider VSC")

	validators, err := queryVAASAllValidators(s.gnoContainer)
	r.NoError(err, "query all validators on Gno consumer")
	r.Len(validators, 1, "Gno consumer should have 1 validator (the AtomOne validator)")
	s.T().Logf("Gno consumer received validator: pubkey=%s, power=%d", validators[0].PubKey, validators[0].Power)

	providerClientID, err := queryVAASProviderClientID(s.gnoContainer)
	r.NoError(err, "provider client ID should be set on Gno consumer")
	s.T().Logf("Provider client ID on Gno: %s", providerClientID)

	s.T().Log("Real VSC flow completed successfully")
}

// createConsumerOnProvider registers the Gno chain as a consumer on the AtomOne
// provider module. Uses a past spawn_time so the consumer launches immediately
// in the next BeginBlock.
func (s *E2ETestSuite) createConsumerOnProvider() {
	ctx := context.Background()

	createConsumerJSON := fmt.Sprintf(`{
  "chain_id": "%s",
  "metadata": {
    "name": "gno-consumer",
    "description": "Gno e2e test consumer chain",
    "metadata": "{}"
  },
  "initialization_parameters": {
    "initial_height": {
      "revision_number": 0,
      "revision_height": 1
    },
    "genesis_hash": "",
    "binary_hash": "",
    "spawn_time": "2024-01-01T00:00:00Z",
    "unbonding_period": 1728000000000000,
    "vaas_timeout_period": 2419200000000000,
    "historical_entries": 10000
  },
  "infraction_parameters": {
    "double_sign": {
      "slash_fraction": "0.05",
      "jail_duration": 9223372036854775807,
      "tombstone": true
    },
    "downtime": {
      "slash_fraction": "0.0001",
      "jail_duration": 600000000000,
      "tombstone": false
    }
  }
}`, s.cfg.GnoChainID)

	_, stderr, err := dockerExecStdin(ctx, s.atomoneContainer, createConsumerJSON,
		"bash", "-c", "cat > /tmp/create_consumer.json")
	s.Require().NoError(err, "write create_consumer.json: %s", stderr)

	txStdout, txStderr, err := dockerExec(ctx, s.atomoneContainer,
		"atomoned", "tx", "provider", "create-consumer", "/tmp/create_consumer.json",
		"--from", s.atomOneSenderAddress,
		"--chain-id", s.cfg.AtomoneChainID,
		"--keyring-backend", "test",
		"--home", "/root/.atomone",
		"--node", "tcp://localhost:26657",
		"--gas-prices", "0.025uphoton",
		"--gas", "auto", "--gas-adjustment", "1.5",
		"--yes", "--output", "json",
	)
	s.Require().NoError(err, "create-consumer tx: %s", txStderr)

	var txResult struct {
		Code   int    `json:"code"`
		RawLog string `json:"raw_log"`
	}
	s.Require().NoError(json.Unmarshal([]byte(strings.TrimSpace(txStdout)), &txResult))
	s.Require().Equal(0, txResult.Code, "create-consumer tx failed: %s", txResult.RawLog)

	s.T().Log("Consumer registered on provider, waiting for launch...")

	s.waitForCondition(30*time.Second, 2*time.Second, func() bool {
		queryOut, _, err := dockerExec(ctx, s.atomoneContainer,
			"atomoned", "q", "provider", "consumer-genesis", "0",
			"--home", "/root/.atomone",
			"--node", "tcp://localhost:26657",
			"--output", "json",
		)
		if err != nil {
			return false
		}
		return queryOut != "" && !strings.Contains(queryOut, "not found") && !strings.Contains(queryOut, "Error")
	}, "consumer genesis not found on provider (consumer not launched)")

	s.T().Log("Consumer launched on provider")
}

func (s *E2ETestSuite) getValidatorOperatorAddress() string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stdout, stderr, err := dockerExec(ctx, s.atomoneContainer,
		"atomoned", "keys", "show", "validator", "--bech", "val", "-a",
		"--keyring-backend", "test", "--home", "/root/.atomone",
	)
	s.Require().NoError(err, "get validator operator address: %s", stderr)
	valAddr := strings.TrimSpace(stdout)
	s.Require().NotEmpty(valAddr)
	return valAddr
}

func (s *E2ETestSuite) delegateTokens(valOperAddr string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	stdout, stderr, err := dockerExec(ctx, s.atomoneContainer,
		"atomoned", "tx", "staking", "delegate", valOperAddr, "1000000uatone",
		"--from", s.atomOneSenderAddress,
		"--chain-id", s.cfg.AtomoneChainID,
		"--keyring-backend", "test",
		"--home", "/root/.atomone",
		"--node", "tcp://localhost:26657",
		"--gas-prices", "0.025uphoton",
		"--gas", "auto", "--gas-adjustment", "1.5",
		"--yes", "--output", "json",
	)
	s.Require().NoError(err, "delegate tx: %s", stderr)

	var txResult struct {
		Code   int    `json:"code"`
		RawLog string `json:"raw_log"`
	}
	s.Require().NoError(json.Unmarshal([]byte(strings.TrimSpace(stdout)), &txResult))
	s.Require().Equal(0, txResult.Code, "delegate tx failed: %s", txResult.RawLog)

	s.T().Logf("Delegated 1000000uatone to %s", valOperAddr)
}

func (s *E2ETestSuite) getProviderValidatorVotingPower() uint64 {
	stdout, _, err := dockerExec(context.Background(), s.atomoneContainer,
		"atomoned", "q", "tendermint-validator-set",
		"--node", "tcp://localhost:26657",
		"--output", "json",
	)
	s.Require().NoError(err, "query tendermint validator set")

	var resp struct {
		Validators []struct {
			VotingPower string `json:"voting_power"`
		} `json:"validators"`
	}
	s.Require().NoError(json.Unmarshal([]byte(strings.TrimSpace(stdout)), &resp))
	s.Require().NotEmpty(resp.Validators, "no validators found")
	power, err := strconv.ParseUint(resp.Validators[0].VotingPower, 10, 64)
	s.Require().NoError(err, "parse voting power")
	return power
}
