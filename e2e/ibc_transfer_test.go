package e2e

import (
	"fmt"
	"time"
)

func (s *E2ETestSuite) TestIBCTransferAtomOneToGno() {
	r := s.Require()

	transferAmount := "10"
	denom := "uatone"
	receiver := s.cfg.GnoReceiver

	// Record sender balance before transfer
	beforeBalance, err := queryAtomOneBalance(s.cfg.AtomoneREST, s.senderAddress, denom)
	r.NoError(err, "query sender balance before transfer")
	s.T().Logf("Sender balance before: %d %s", beforeBalance, denom)

	// Build and broadcast MsgSendPacket
	msg := buildMsgSendPacket(
		s.atomoneClientID, s.senderAddress, receiver,
		denom, transferAmount, time.Now().Add(time.Hour).Unix(),
	)
	s.T().Logf("Broadcasting MsgSendPacket: %s %s → %s", transferAmount, denom, receiver)

	txHash := s.signAndBroadcastAtomOneTx(msg)
	s.T().Logf("IBC transfer submitted: txhash=%s", txHash)

	// Verify sender balance decreased (tokens escrowed for IBC transfer)
	s.T().Log("Verifying sender balance decreased on AtomOne...")
	r.Eventually(func() bool {
		afterBalance, err := queryAtomOneBalance(s.cfg.AtomoneREST, s.senderAddress, denom)
		if err != nil {
			return false
		}
		return afterBalance <= beforeBalance-10
	}, 30*time.Second, 2*time.Second, "sender balance did not decrease on AtomOne")

	// Compute expected IBC denom hash on Gno
	ibcHash := computeIBCDenomHash(s.gnoClientID, denom)
	ibcDenom := fmt.Sprintf("ibc/%s", ibcHash)
	s.T().Logf("Expected IBC denom: %s", ibcDenom)

	// Record GRC20 balance before relay
	beforeGRC20, _ := queryGRC20Balance(s.gnoContainer, ibcHash, receiver)

	// Wait for GRC20 balance to increase on Gno
	s.T().Logf("Waiting for GRC20 balance on Gno (before: %d)...", beforeGRC20)
	var balance int64
	r.Eventually(func() bool {
		bal, err := queryGRC20Balance(s.gnoContainer, ibcHash, receiver)
		if err != nil {
			return false
		}
		balance = bal
		return balance >= beforeGRC20+10
	}, 2*time.Minute, 3*time.Second, "GRC20 balance not received on Gno")

	s.T().Logf("GRC20 balance verified: %d (before: %d, expected +%s)", balance, beforeGRC20, transferAmount)
}

func (s *E2ETestSuite) TestIBCTransferGnoToAtomOne() {
	r := s.Require()

	transferAmount := int64(100)
	denom := "ugnot"
	receiver := s.senderAddress // AtomOne validator address
	timeout := fmt.Sprintf("%d", time.Now().Add(time.Hour).Unix())

	// Record sender balance before transfer
	beforeGnoBalance, err := queryGnoBalance(s.gnoContainer, s.gnoSenderAddress, denom)
	r.NoError(err, "query gno sender balance before transfer")
	s.T().Logf("Gno sender balance before: %d %s", beforeGnoBalance, denom)

	s.T().Logf("Broadcasting Gno Transfer: %d %s → %s", transferAmount, denom, receiver)

	s.signAndBroadcastGnoCall("test",
		"gno.land/r/aib/ibc/apps/transfer", "Transfer",
		fmt.Sprintf("%d%s", transferAmount, denom),
		s.gnoClientID, receiver, timeout,
	)
	s.T().Log("Gno transfer submitted")

	// Verify sender balance decreased (tokens escrowed for IBC transfer)
	s.T().Log("Verifying sender balance decreased on Gno...")
	r.Eventually(func() bool {
		afterBalance, err := queryGnoBalance(s.gnoContainer, s.gnoSenderAddress, denom)
		if err != nil {
			return false
		}
		return afterBalance <= beforeGnoBalance-transferAmount
	}, 30*time.Second, 2*time.Second, "sender balance did not decrease on Gno")

	// Compute expected IBC denom on AtomOne
	// ugnot arrives as ibc/SHA256("transfer/<atomoneClientID>/ugnot")
	ibcHash := computeIBCDenomHash(s.atomoneClientID, denom)
	ibcDenom := fmt.Sprintf("ibc/%s", ibcHash)
	s.T().Logf("Expected IBC denom on AtomOne: %s", ibcDenom)

	// Record balance before relay
	beforeAtomOneBalance, _ := queryAtomOneBalance(s.cfg.AtomoneREST, receiver, ibcDenom)
	s.T().Logf("AtomOne IBC balance before: %d", beforeAtomOneBalance)

	// Wait for IBC voucher token on AtomOne
	s.T().Log("Waiting for IBC voucher token on AtomOne...")
	var balance int64
	r.Eventually(func() bool {
		bal, err := queryAtomOneBalance(s.cfg.AtomoneREST, receiver, ibcDenom)
		if err != nil {
			return false
		}
		balance = bal
		return balance >= beforeAtomOneBalance+transferAmount
	}, 2*time.Minute, 3*time.Second, "IBC voucher balance not received on AtomOne")

	s.T().Logf("AtomOne IBC balance verified: %d (before: %d, expected +%d)", balance, beforeAtomOneBalance, transferAmount)
}
