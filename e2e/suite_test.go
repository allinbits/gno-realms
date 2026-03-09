package e2e

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/suite"
)

type E2ETestSuite struct {
	suite.Suite
	cfg                  *Config
	atomoneClientID      string
	gnoClientID          string
	atomOneSenderAddress string
	gnoSenderAddress     string
	atomoneContainer     string
	gnoContainer         string
}

func TestE2E(t *testing.T) {
	suite.Run(t, new(E2ETestSuite))
}

func (s *E2ETestSuite) SetupSuite() {
	cfg, err := LoadConfig()
	s.Require().NoError(err, "load config")
	s.Require().NotEmpty(cfg.TestMnemonic, "TEST_MNEMONIC must be set")
	s.cfg = cfg

	// Verify atomone is healthy
	_, err = httpGet(cfg.AtomoneREST + "/cosmos/base/tendermint/v1beta1/node_info")
	s.Require().NoError(err, "atomone REST not reachable at %s", cfg.AtomoneREST)

	// Get container IDs
	s.atomoneContainer, err = getContainerID("atomone")
	s.Require().NoError(err, "get atomone container ID")
	s.gnoContainer, err = getContainerID("gno")
	s.Require().NoError(err, "get gno container ID")

	// Verify gno is healthy via gnokey query
	_, err = gnoQuery(s.gnoContainer, "r/aib/ibc/core", "")
	s.Require().NoError(err, "gno node not reachable")

	// Get sender address from the validator key in the atomone container
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stdout, stderr, err := dockerExec(ctx, s.atomoneContainer,
		"atomoned", "keys", "show", "validator", "-a",
		"--keyring-backend", "test", "--home", "/root/.atomone")
	s.Require().NoError(err, "get validator address: %s", stderr)
	s.atomOneSenderAddress = strings.TrimSpace(stdout)
	s.Require().NotEmpty(s.atomOneSenderAddress)
	s.T().Logf("AtomOne sender address: %s", s.atomOneSenderAddress)

	// Recover test key in gnokey for Gno→AtomOne transfers
	s.recoverGnoKey("test", cfg.TestMnemonic)
	s.gnoSenderAddress = s.gnoKeyAddress("test")
	s.T().Logf("Gno sender address: %s", s.gnoSenderAddress)

	// Wait for IBC clients
	s.waitForIBCClients()
}

func (s *E2ETestSuite) waitForIBCClients() {
	r := s.Require()

	// Wait for client on AtomOne
	r.Eventually(func() bool {
		id, err := queryAtomOneClientStates(s.cfg.AtomoneREST)
		if err != nil {
			return false
		}
		s.atomoneClientID = id
		return true
	}, 3*time.Minute, 2*time.Second, "IBC client on AtomOne not created in time")
	s.T().Logf("AtomOne client ID: %s", s.atomoneClientID)

	// Wait for client on Gno
	r.Eventually(func() bool {
		id, err := queryGnoClients(s.gnoContainer)
		if err != nil {
			return false
		}
		s.gnoClientID = id
		return true
	}, 3*time.Minute, 2*time.Second, "IBC client on Gno not created in time")
	s.T().Logf("Gno client ID: %s", s.gnoClientID)

	// Wait for counterparty registration
	r.Eventually(func() bool {
		_, err := queryGnoClientCounterparty(s.gnoContainer, s.gnoClientID)
		return err == nil
	}, 1*time.Minute, 2*time.Second, "counterparty not registered on Gno in time")
	s.T().Log("Counterparty registered")
}

// recoverGnoKey recovers a key in gnokey inside the gno container from a mnemonic.
func (s *E2ETestSuite) recoverGnoKey(keyName, mnemonic string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// gnokey add --recover reads: mnemonic first, then passphrase (empty = unencrypted)
	stdin := fmt.Sprintf("%s\n\n", mnemonic)
	_, stderr, err := dockerExecStdin(ctx, s.gnoContainer, stdin,
		"gnokey", "add", keyName, "--recover", "--insecure-password-stdin", "--force")
	s.Require().NoError(err, "gnokey add --recover: %s", stderr)
}

// gnoKeyAddress returns the address associated with a gnokey key name.
func (s *E2ETestSuite) gnoKeyAddress(keyName string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stdout, stderr, err := dockerExec(ctx, s.gnoContainer, "gnokey", "list")
	s.Require().NoError(err, "gnokey list: %s", stderr)
	// Output format: "0. keyname (local) - addr: g1... pub: gpub1..."
	for line := range strings.SplitSeq(stdout, "\n") {
		if strings.Contains(line, keyName) {
			idx := strings.Index(line, "addr: ")
			if idx >= 0 {
				rest := line[idx+len("addr: "):]
				return strings.Fields(rest)[0]
			}
		}
	}
	s.Require().Fail("key not found", "key %s not found in gnokey list output: %s", keyName, stdout)
	return ""
}
