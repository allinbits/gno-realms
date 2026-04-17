package e2e

import (
	"fmt"
	"time"
)

func (s *E2ETestSuite) TestVoucherSendApprove() {
	var (
		r              = s.Require()
		transferAmount = int64(100)
		sendAmount     = int64(40)
		approveAmount  = int64(50)
		spendAmount    = int64(30)
		denom          = "uatone"
		owner          = s.gnoSenderAddress
		sendRecipient  = gnoPkgAddress("e2e/voucher-send-recipient")
		spendRecipient = gnoPkgAddress("e2e/voucher-approve-recipient")
		timeout        = time.Now().Add(time.Hour).Unix()
	)

	// Compute expected IBC denom and grc20reg key
	denomHash := computeIBCDenomHash(s.gnoClientID, denom)
	ibcDenom := "ibc/" + denomHash
	grc20regKey := "gno.land/r/aib/ibc/apps/transfer." + denomHash
	s.T().Logf("IBC denom: %s", ibcDenom)

	// Create and fund the spender account
	spender := s.addGnoKey("voucher-spender")
	s.T().Logf("Spender address: %s", spender)
	s.sendGnoCoins(owner, spender, "10000000ugnot")
	s.T().Log("Spender funded")

	// Transfer uatone from AtomOne to Gno to mint voucher tokens
	s.T().Logf("Minting voucher tokens via IBC transfer (%d %s)...", transferAmount, denom)
	beforeVoucher, _ := queryVoucherBalance(s.gnoContainer, owner, ibcDenom)
	msg := buildMsgSendPacket(
		s.atomoneClientID, s.atomOneSenderAddress, owner,
		denom, transferAmount, timeout,
	)
	s.signAndBroadcastAtomOneTx(s.atomOneSenderAddress, msg)

	// Wait for vouchers to arrive on Gno
	r.Eventually(func() bool {
		bal, err := queryVoucherBalance(s.gnoContainer, owner, ibcDenom)
		if err != nil {
			return false
		}
		return bal >= beforeVoucher+transferAmount
	}, 2*time.Minute, time.Second, "voucher tokens not received on Gno")
	s.T().Log("Voucher tokens minted")

	// ----------------
	// Test VoucherSend
	// ----------------
	beforeOwner, err := queryVoucherBalance(s.gnoContainer, owner, ibcDenom)
	r.NoError(err, "query owner voucher balance before VoucherSend")
	s.T().Logf("Owner balance before VoucherSend: %d", beforeOwner)

	s.T().Logf("VoucherSend %d → %s", sendAmount, sendRecipient)
	s.signAndBroadcastGnoCall(owner,
		"gno.land/r/aib/ibc/apps/transfer", "VoucherSend",
		"",
		ibcDenom, sendRecipient, fmt.Sprint(sendAmount),
	)

	afterOwner, err := queryVoucherBalance(s.gnoContainer, owner, ibcDenom)
	r.NoError(err, "query owner voucher balance after VoucherSend")
	afterSendRecipient, err := queryVoucherBalance(s.gnoContainer, sendRecipient, ibcDenom)
	r.NoError(err, "query sendRecipient voucher balance after VoucherSend")

	r.Equal(beforeOwner-sendAmount, afterOwner, "owner balance did not decrease")
	r.Equal(sendAmount, afterSendRecipient, "sendRecipient balance mismatch")
	s.T().Logf("After VoucherSend: owner=%d, sendRecipient=%d", afterOwner, afterSendRecipient)

	// -------------------
	// Test VoucherApprove
	// -------------------
	beforeOwner = afterOwner

	s.T().Logf("VoucherApprove %d for spender %s", approveAmount, spender)
	s.signAndBroadcastGnoCall(owner,
		"gno.land/r/aib/ibc/apps/transfer", "VoucherApprove",
		"",
		ibcDenom, spender, fmt.Sprint(approveAmount),
	)
	s.T().Log("VoucherApprove succeeded")

	// Spender exercises the allowance via MsgRun TransferFrom
	s.T().Logf("Spender TransferFrom %d → %s", spendAmount, spendRecipient)
	script := fmt.Sprintf(`package main

import "gno.land/r/demo/defi/grc20reg"

func main() {
	token := grc20reg.MustGet("%s")
	if err := token.CallerTeller().TransferFrom(address("%s"), address("%s"), %d); err != nil {
		panic(err)
	}
}
`, grc20regKey, owner, spendRecipient, spendAmount)
	s.signAndBroadcastGnoRun(spender, script)
	s.T().Log("TransferFrom succeeded")

	afterOwner, err = queryVoucherBalance(s.gnoContainer, owner, ibcDenom)
	r.NoError(err, "query owner voucher balance after TransferFrom")
	afterSpendRecipient, err := queryVoucherBalance(s.gnoContainer, spendRecipient, ibcDenom)
	r.NoError(err, "query spendRecipient voucher balance after TransferFrom")

	r.Equal(beforeOwner-spendAmount, afterOwner, "owner balance did not decrease by spend amount")
	r.Equal(spendAmount, afterSpendRecipient, "spendRecipient did not receive spend amount")
	s.T().Logf("After TransferFrom: owner=%d, spendRecipient=%d", afterOwner, afterSpendRecipient)
}
