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

	// Record voucher balance before relay
	beforeVoucher, _ := queryVoucherBalance(s.gnoContainer, receiver, ibcDenom)

	// Wait for voucher balance to increase on Gno
	s.T().Logf("Waiting for voucher balance on Gno (before: %d)...", beforeVoucher)
	var afterVoucher int64
	r.Eventually(func() bool {
		bal, err := queryVoucherBalance(s.gnoContainer, receiver, ibcDenom)
		if err != nil {
			return false
		}
		afterVoucher = bal
		return afterVoucher == beforeVoucher+transferAmount
	}, time.Minute/2, time.Second, "voucher balance not received on Gno")

	s.T().Logf("voucher balance verified: %d (before: %d, expected +%d)", afterVoucher, beforeVoucher, transferAmount)

	// Query Gno transfer realm denom info and verify the trace is correctly parsed.
	denomInfo, err := queryGnoIBCDenom(s.gnoContainer, ibcDenom)
	r.NoError(err, "query IBC denom info on Gno")
	r.Equal(denom, denomInfo.Base, "IBC denom base should be the original denom")
	r.Equal(ibcDenom, denomInfo.Denom, "IBC denom should match")
	s.T().Logf("IBC denom verified: base=%s path=%s denom=%s", denomInfo.Base, denomInfo.Path, denomInfo.Denom)

	// -----------------------------------
	// Transfer back the atones to AtomOne
	// -----------------------------------
	sender = s.gnoSenderAddress
	receiver = s.atomOneSenderAddress
	beforeVoucher = afterVoucher
	beforeAtomOneBalance = afterAtomOneBalance
	s.T().Logf("Sending %d%s from %s to %s...", transferAmount, ibcDenom, sender, receiver)

	s.signAndBroadcastGnoCall(sender,
		"gno.land/r/aib/ibc/apps/transfer", "Transfer",
		"", // no -send coins for voucher transfer
		s.gnoClientID, receiver, ibcDenom, fmt.Sprint(transferAmount), fmt.Sprint(timeout), "",
	)
	s.T().Log("Gno transfer IBC voucher submitted")

	// Verify sender balance decreased (tokens escrowed for IBC transfer)
	s.T().Log("Verifying sender balance decreased on Gno...")
	r.Eventually(func() bool {
		bal, err := queryVoucherBalance(s.gnoContainer, sender, ibcDenom)
		if err != nil {
			return false
		}
		afterVoucher = bal
		return afterVoucher == beforeVoucher-transferAmount
	}, time.Minute/2, time.Second, "sender balance did not decrease on Gno")
	s.T().Logf("voucher balance verified: %d (before: %d, expected -%d)", afterVoucher, beforeVoucher, transferAmount)

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
		s.gnoClientID, receiver, denom, fmt.Sprint(transferAmount), fmt.Sprint(timeout), "",
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

	// Query ibc-go denom info and verify the trace is correctly parsed.
	denomHash := computeIBCDenomHash(s.atomoneClientID, denom)
	denomInfo, err := queryAtomOneIBCDenom(s.cfg.AtomoneREST, denomHash)
	r.NoError(err, "query IBC denom info on AtomOne")
	r.Equal(denom, denomInfo.Base, "IBC denom base should be the original denom")
	r.Len(denomInfo.Trace, 1, "IBC denom should have exactly one trace hop")
	r.Equal("transfer", denomInfo.Trace[0].PortID, "trace hop port should be 'transfer'")
	r.Equal(s.atomoneClientID, denomInfo.Trace[0].ChannelID, "trace hop channel/client should be the AtomOne client ID")
	s.T().Logf("IBC denom verified: base=%s trace=%v", denomInfo.Base, denomInfo.Trace)

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
		afterGnoBalance = bal
		return afterGnoBalance == beforeGnoBalance+transferAmount
	}, time.Minute/2, time.Second, "gnot balance not received on Gno")

	s.T().Logf("Gno balance verified: %d (before: %d, expected +%d)", afterGnoBalance, beforeGnoBalance, transferAmount)
}

func (s *E2ETestSuite) TestIBCTransferGRC20GnoToAtomOne() {
	var (
		r              = s.Require()
		mintAmount     = int64(1000000)
		transferAmount = int64(100)
		denom          = "gno.land/r/aib/ibc/apps/testing/grc20test.my:exotic/slug%2F"
		sender         = s.gnoSenderAddress
		receiver       = s.atomOneSenderAddress
		timeout        = time.Now().Add(time.Hour).Unix()
		transferApp    = gnoPkgAddress("gno.land/r/aib/ibc/apps/transfer")
	)
	s.T().Logf("Transfer app address: %s", transferApp)

	// Record balance before mint
	balanceBeforeMint, err := queryGnoGRC20TestBalance(s.gnoContainer, sender)
	r.NoError(err, "query GRC20 test balance before mint")

	// Mint GRC20 test tokens to the sender
	s.T().Logf("Minting %d TEST tokens to %s...", mintAmount, sender)
	s.signAndBroadcastGnoCall(sender,
		"gno.land/r/aib/ibc/apps/testing/grc20test", "Mint",
		"",
		sender, fmt.Sprint(mintAmount),
	)

	// Verify mint
	beforeBalance, err := queryGnoGRC20TestBalance(s.gnoContainer, sender)
	r.NoError(err, "query GRC20 test balance after mint")
	r.Equal(balanceBeforeMint+mintAmount, beforeBalance, "minted balance mismatch")
	s.T().Logf("GRC20 test balance after mint: %d", beforeBalance)

	// Approve the transfer app to spend tokens
	s.T().Logf("Approving %s to spend %d tokens...", transferApp, transferAmount)
	s.signAndBroadcastGnoCall(sender,
		"gno.land/r/aib/ibc/apps/testing/grc20test", "Approve",
		"",
		sender, transferApp, fmt.Sprint(transferAmount),
	)

	// Call Transfer
	s.T().Logf("Sending %d %s from %s to %s...", transferAmount, denom, sender, receiver)
	s.signAndBroadcastGnoCall(sender,
		"gno.land/r/aib/ibc/apps/transfer", "Transfer",
		"",
		s.gnoClientID, receiver, denom, fmt.Sprint(transferAmount), fmt.Sprint(timeout), "",
	)
	s.T().Log("GRC20 transfer submitted")

	// Verify sender balance decreased on Gno (tokens escrowed)
	s.T().Log("Verifying sender GRC20 balance decreased on Gno...")
	var afterBalance int64
	r.Eventually(func() bool {
		bal, err := queryGnoGRC20TestBalance(s.gnoContainer, sender)
		if err != nil {
			return false
		}
		afterBalance = bal
		return afterBalance == beforeBalance-transferAmount
	}, time.Minute/2, time.Second, "sender GRC20 balance did not decrease on Gno")
	s.T().Logf("GRC20 balance verified: %d (before: %d, expected -%d)", afterBalance, beforeBalance, transferAmount)

	// Query the grc20 alias from the transfer realm via qeval.
	alias, err := queryGnoGRC20Alias(s.gnoContainer, denom)
	r.NoError(err, "query GRC20 alias from transfer realm")
	ibcDenom := "ibc/" + computeIBCDenomHash(s.atomoneClientID, alias)
	s.T().Logf("GRC20 alias: %s", alias)
	s.T().Logf("Expected IBC denom on AtomOne: %s", ibcDenom)

	// Wait for IBC voucher on AtomOne
	beforeAtomOneBalance, _ := queryAtomOneBalance(s.cfg.AtomoneREST, receiver, ibcDenom)
	s.T().Logf("Waiting for IBC voucher on AtomOne (before: %d)...", beforeAtomOneBalance)
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

	// Query ibc-go denom info and verify the trace is correctly parsed.
	// The alias (slashes replaced with colons) should be the base denom, with a single trace
	// hop of transfer/<atomoneClientID>.
	denomHash := computeIBCDenomHash(s.atomoneClientID, alias)
	denomInfo, err := queryAtomOneIBCDenom(s.cfg.AtomoneREST, denomHash)
	r.NoError(err, "query IBC denom info on AtomOne")
	r.Equal(alias, denomInfo.Base, "IBC denom base should be the grc20 alias")
	r.Len(denomInfo.Trace, 1, "IBC denom should have exactly one trace hop")
	r.Equal("transfer", denomInfo.Trace[0].PortID, "trace hop port should be 'transfer'")
	r.Equal(s.atomoneClientID, denomInfo.Trace[0].ChannelID, "trace hop channel/client should be the AtomOne client ID")
	s.T().Logf("IBC denom verified: base=%s trace=%v", denomInfo.Base, denomInfo.Trace)

	// ----------------------------------------
	// Transfer back the GRC20 tokens to Gno
	// ----------------------------------------
	sender = s.atomOneSenderAddress
	receiver = s.gnoSenderAddress
	beforeAtomOneBalance = afterAtomOneBalance
	beforeBalance = afterBalance
	s.T().Logf("Sending %d %s back from %s to %s...", transferAmount, ibcDenom, sender, receiver)

	// Build and broadcast MsgSendPacket on AtomOne.
	// The denom in the packet must be the full IBC path (trace + alias).
	msg := buildMsgSendPacket(
		s.atomoneClientID, sender, receiver,
		fmt.Sprintf("transfer/%s/%s", s.atomoneClientID, alias),
		transferAmount, timeout,
	)
	s.signAndBroadcastAtomOneTx(sender, msg)
	s.T().Log("AtomOne IBC transfer confirmed")

	// Verify sender balance decreased on AtomOne (voucher burned)
	s.T().Log("Verifying sender balance decreased on AtomOne...")
	afterAtomOneBalance, err = queryAtomOneBalance(s.cfg.AtomoneREST, sender, ibcDenom)
	r.NoError(err, "query AtomOne balance after transfer back")
	r.Equal(beforeAtomOneBalance-transferAmount, afterAtomOneBalance, "sender balance did not decrease on AtomOne")
	s.T().Logf("AtomOne balance verified: %d (before: %d, expected -%d)", afterAtomOneBalance, beforeAtomOneBalance, transferAmount)

	// Wait for GRC20 tokens to be unescrowed on Gno
	s.T().Log("Waiting for GRC20 tokens back on Gno...")
	r.Eventually(func() bool {
		bal, err := queryGnoGRC20TestBalance(s.gnoContainer, receiver)
		if err != nil {
			return false
		}
		afterBalance = bal
		return afterBalance == beforeBalance+transferAmount
	}, time.Minute/2, time.Second, "GRC20 balance not unescrowed on Gno")

	s.T().Logf("GRC20 balance verified: %d (before: %d, expected +%d)", afterBalance, beforeBalance, transferAmount)
}
