package transfer

// TODO: MintVoucherForTesting must not be callable in production.
// Either exclude this file from deployment, or refactor filetests to mint
// vouchers via a real RecvPacket flow instead of using this helper.

// MintVoucherForTesting creates a GRC20 voucher token and mints it to the
// given address. It also registers the denom in the transfer app's state.
// This is intended for use in filetests only.
func MintVoucherForTesting(cur realm, denomPath string, to address, amount int64) {
	denom := ExtractDenomFromPath(denomPath)
	ibcDenom := denom.IBCDenom()
	if !hasDenom(ibcDenom) {
		setDenom(denom)
	}
	inst := getOrCreateGRC20(denom.Base, ibcDenom)
	if err := inst.ledger.Mint(to, amount); err != nil {
		panic("MintVoucherForTesting: " + err.Error())
	}
}

// GRC20BalanceOf returns the GRC20 balance of a voucher token for a given address.
// Returns 0 if the token does not exist.
func GRC20BalanceOf(ibcDenom string, addr address) int64 {
	inst := getGRC20(ibcDenom)
	if inst == nil {
		return 0
	}
	return inst.token.BalanceOf(addr)
}
