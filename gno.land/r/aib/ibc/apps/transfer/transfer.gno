package transfer

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Transfer is the entry point for sending tokens to another chain using the
// IBC protocol. It supports three token types, detected automatically from the
// denom argument:
//   - IBC voucher (denom starts with "ibc/"): burns the voucher GRC20 token.
//   - Non-IBC GRC20 token (registered in grc20reg): escrows via TransferFrom.
//   - Native coin (everything else): the coin must be sent with the transaction
//     via the send field, and must match denom and amount.
//
// memo is included in the IBC packet payload.
//
// The classification and the packet construction are the implementation's
// (see upgrade.gno). Two things stay here: the value-moving authority must
// come from a direct user call, because the packet sender is the tx origin and
// unsafe.OriginSend describes coins that actually landed at this realm (an
// intermediate realm or a `maketx run` script can attach coins to the tx and
// spend them elsewhere); and the sends the implementation records for
// OnSendPacket are cleared on every exit path, so nothing bleeds into a
// later transaction.
func Transfer(cur realm, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	if !cur.Previous().IsUserCall() {
		panic("transfer must be a direct user call (maketx call)")
	}
	defer clearPendingSends()
	return mustImpl().Transfer(0, cur, clientID, receiver, denom, amount, timeoutTimestamp, memo)
}

// VoucherSend is a convenience helper to send an IBC voucher token from the
// caller to the provided recipient.
func VoucherSend(cur realm, ibcDenom string, to address, amount int64) {
	inst := getVoucher(ibcDenom)
	if inst == nil {
		panic(ufmt.Errorf("voucher token not found for denom %s", ibcDenom))
	}
	teller := inst.ledger.ImpersonateTeller(cur.Previous().Address())
	if err := teller.Transfer(0, cur, to, amount); err != nil {
		panic(ufmt.Errorf("transfer voucher %s error: %v", ibcDenom, err))
	}
}

// VoucherApprove is a convenience helper to set a spender allowance for an IBC
// voucher token on behalf of the caller.
func VoucherApprove(cur realm, ibcDenom string, spender address, amount int64) {
	inst := getVoucher(ibcDenom)
	if inst == nil {
		panic(ufmt.Errorf("voucher token not found for denom %s", ibcDenom))
	}
	teller := inst.ledger.ImpersonateTeller(cur.Previous().Address())
	if err := teller.Approve(0, cur, spender, amount); err != nil {
		panic(ufmt.Errorf("approve voucher %s error: %v", ibcDenom, err))
	}
}
