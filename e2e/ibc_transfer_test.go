package e2e

import (
	"fmt"
	"time"
)

func (s *E2ETestSuite) TestIBCTransferAtomOneToGno() {
	var (
		r              = s.Require()
		transferAmount = int64(10)
		denom          = "uatone"
		sender         = s.atomOneSenderAddress
		receiver       = s.gnoSenderAddress
		timeout        = time.Now().Add(time.Hour).Unix()
	)
	s.T().Logf("Sending %d%s from %s to %s...", transferAmount, denom, sender, receiver)

	// Record sender balance before transfer
	beforeAtomOneBalance, err := queryAtomOneBalance(s.cfg.AtomoneREST, sender, denom)
	r.NoError(err, "query sender balance before transfer")
	s.T().Logf("Sender balance before: %d %s", beforeAtomOneBalance, denom)

	// Build and broadcast MsgSendPacket
	msg := buildMsgSendPacket(
		s.atomoneClientID, sender, receiver,
		denom, transferAmount, timeout,
	)
	s.T().Logf("Broadcasting MsgSendPacket: %d %s → %s", transferAmount, denom, receiver)

	s.signAndBroadcastAtomOneTx(sender, msg)
	s.T().Log("IBC transfer confirmed")

	// Verify sender balance decreased (tokens escrowed for IBC transfer)
	s.T().Log("Verifying sender balance decreased on AtomOne...")
	afterAtomOneBalance, err := queryAtomOneBalance(s.cfg.AtomoneREST, sender, denom)
	r.NoError(err, "query sender balance after transfer")
	r.Equal(beforeAtomOneBalance-transferAmount, afterAtomOneBalance, "sender balance did not decrease on AtomOne")
	s.T().Logf("AtomOne balance verified: %d (before: %d, expected -%d)", afterAtomOneBalance, beforeAtomOneBalance, transferAmount)

	// Compute expected IBC denom hash on Gno
	ibcDenom := "ibc/" + computeIBCDenomHash(s.gnoClientID, denom)
	s.T().Logf("Expected IBC denom: %s", ibcDenom)

	// Record GRC20 balance before relay
	beforeGRC20, _ := queryGnoGRC20Balance(s.gnoContainer, receiver, ibcDenom)

	// Wait for GRC20 balance to increase on Gno
	s.T().Logf("Waiting for GRC20 balance on Gno (before: %d)...", beforeGRC20)
	var afterGRC20 int64
	r.Eventually(func() bool {
		bal, err := queryGnoGRC20Balance(s.gnoContainer, receiver, ibcDenom)
		if err != nil {
			return false
		}
		afterGRC20 = bal
		return afterGRC20 == beforeGRC20+transferAmount
	}, time.Minute/2, time.Second, "GRC20 balance not received on Gno")

	s.T().Logf("GRC20 balance verified: %d (before: %d, expected +%d)", afterGRC20, beforeGRC20, transferAmount)

	// -----------------------------------
	// Transfer back the atones to AtomOne
	// -----------------------------------
	sender = s.gnoSenderAddress
	receiver = s.atomOneSenderAddress
	beforeGRC20 = afterGRC20
	beforeAtomOneBalance = afterAtomOneBalance
	s.T().Logf("Sending %d%s from %s to %s...", transferAmount, ibcDenom, sender, receiver)

	s.signAndBroadcastGnoCall(sender,
		"gno.land/r/aib/ibc/apps/transfer", "TransferGRC20",
		"", // no -send coins for GRC20 transfer
		s.gnoClientID, receiver, ibcDenom, fmt.Sprint(transferAmount), fmt.Sprint(timeout), "",
	)
	s.T().Log("Gno transfer IBC voucher submitted")

	// Verify sender balance decreased (tokens escrowed for IBC transfer)
	s.T().Log("Verifying sender balance decreased on Gno...")
	r.Eventually(func() bool {
		bal, err := queryGnoGRC20Balance(s.gnoContainer, sender, ibcDenom)
		if err != nil {
			return false
		}
		afterGRC20 = bal
		return afterGRC20 == beforeGRC20-transferAmount
	}, time.Minute/2, time.Second, "sender balance did not decrease on Gno")
	s.T().Logf("GRC20 balance verified: %d (before: %d, expected -%d)", afterGRC20, beforeGRC20, transferAmount)

	// Wait for atone token on AtomOne
	s.T().Log("Waiting for atone token back on AtomOne...")
	r.Eventually(func() bool {
		bal, err := queryAtomOneBalance(s.cfg.AtomoneREST, receiver, denom)
		if err != nil {
			return false
		}
		afterAtomOneBalance = bal
		return afterAtomOneBalance == beforeAtomOneBalance+transferAmount
	}, time.Minute/2, time.Second, "atone balance not received on AtomOne")

	s.T().Logf("AtomOne IBC balance verified: %d (before: %d, expected +%d)", afterAtomOneBalance, beforeAtomOneBalance, transferAmount)
}

func (s *E2ETestSuite) TestIBCTransferGnoToAtomOne() {
	var (
		r              = s.Require()
		transferAmount = int64(100)
		denom          = "ugnot"
		sender         = s.gnoSenderAddress
		receiver       = s.atomOneSenderAddress // AtomOne validator address
		timeout        = time.Now().Add(time.Hour).Unix()
	)
	s.T().Logf("Sending %d%s from %s to %s...", transferAmount, denom, sender, receiver)

	// Record sender balance before transfer
	beforeGnoBalance, err := queryGnoBalance(s.gnoContainer, sender, denom)
	r.NoError(err, "query gno sender balance before transfer")
	s.T().Logf("Gno sender balance before: %d %s", beforeGnoBalance, denom)

	s.T().Logf("Broadcasting Gno Transfer: %d %s → %s", transferAmount, denom, receiver)

	s.signAndBroadcastGnoCall(sender,
		"gno.land/r/aib/ibc/apps/transfer", "Transfer",
		fmt.Sprintf("%d%s", transferAmount, denom),
		s.gnoClientID, receiver, fmt.Sprint(timeout), "",
	)
	s.T().Log("Gno transfer submitted")

	// Verify sender balance decreased (tokens escrowed for IBC transfer)
	s.T().Log("Verifying sender balance decreased on Gno...")
	var afterGnoBalance int64
	r.Eventually(func() bool {
		bal, err := queryGnoBalance(s.gnoContainer, sender, denom)
		if err != nil {
			return false
		}
		afterGnoBalance = bal
		return afterGnoBalance <= beforeGnoBalance-transferAmount
	}, time.Minute/2, time.Second, "sender balance did not decrease on Gno")
	s.T().Logf("Gno balance verified: %d (before: %d, expected -%d)", afterGnoBalance, beforeGnoBalance, transferAmount)

	// Compute expected IBC denom on AtomOne
	// ugnot arrives as ibc/SHA256("transfer/<atomoneClientID>/ugnot")
	ibcDenom := "ibc/" + computeIBCDenomHash(s.atomoneClientID, denom)
	s.T().Logf("Expected IBC denom on AtomOne: %s", ibcDenom)

	// Record balance before relay
	beforeAtomOneBalance, _ := queryAtomOneBalance(s.cfg.AtomoneREST, receiver, ibcDenom)
	s.T().Logf("AtomOne IBC balance before: %d", beforeAtomOneBalance)

	// Wait for IBC voucher token on AtomOne
	s.T().Log("Waiting for IBC voucher token on AtomOne...")
	var afterAtomOneBalance int64
	r.Eventually(func() bool {
		bal, err := queryAtomOneBalance(s.cfg.AtomoneREST, receiver, ibcDenom)
		if err != nil {
			return false
		}
		afterAtomOneBalance = bal
		return afterAtomOneBalance == beforeAtomOneBalance+transferAmount
	}, time.Minute*2, time.Second, "IBC voucher balance not received on AtomOne")

	s.T().Logf("AtomOne IBC balance verified: %d (before: %d, expected +%d)", afterAtomOneBalance, beforeAtomOneBalance, transferAmount)

	// ------------------------------
	// Transfer back the gnots to Gno
	// ------------------------------
	sender = s.atomOneSenderAddress
	receiver = s.gnoSenderAddress
	beforeAtomOneBalance = afterAtomOneBalance
	beforeGnoBalance = afterGnoBalance
	s.T().Logf("Sending %d%s from %s to %s...", transferAmount, ibcDenom, sender, receiver)

	// Build and broadcast MsgSendPacket
	msg := buildMsgSendPacket(
		s.atomoneClientID, sender, receiver,
		fmt.Sprintf("transfer/%s/%s", s.atomoneClientID, denom), // denom must be the IBC path, not the trace!
		transferAmount, timeout,
	)
	s.T().Logf("Broadcasting MsgSendPacket: %d %s → %s", transferAmount, ibcDenom, receiver)

	s.signAndBroadcastAtomOneTx(sender, msg)
	s.T().Log("IBC transfer confirmed")

	// Verify sender balance decreased (tokens burned for IBC transfer)
	s.T().Log("Verifying sender balance decreased on AtomOne...")
	afterAtomOneBalance, err = queryAtomOneBalance(s.cfg.AtomoneREST, sender, ibcDenom)
	r.NoError(err, "query sender balance after transfer")
	r.Equal(beforeAtomOneBalance-transferAmount, afterAtomOneBalance, "sender balance did not decrease on AtomOne")
	s.T().Logf("AtomOne balance verified: %d (before: %d, expected -%d)", afterAtomOneBalance, beforeAtomOneBalance, transferAmount)

	// Wait for gnot token on Gno
	s.T().Log("Waiting for gno token back on Gno...")
	r.Eventually(func() bool {
		bal, err := queryGnoBalance(s.gnoContainer, receiver, denom)
		if err != nil {
			return false
		}
		fmt.Println("BAL", bal, denom)
		afterGnoBalance = bal
		return afterGnoBalance == beforeGnoBalance+transferAmount
	}, time.Minute/2, time.Second, "gnot balance not received on Gno")

	s.T().Logf("Gno balance verified: %d (before: %d, expected +%d)", afterGnoBalance, beforeGnoBalance, transferAmount)
}
