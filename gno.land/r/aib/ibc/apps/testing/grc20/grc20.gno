// Package grc20 provides a test GRC20 token for IBC transfer testing.
package grc20

import (
	"gno.land/p/demo/tokens/grc20"
	"gno.land/r/demo/defi/grc20reg"
)

var (
	Token, ledger = grc20.NewToken("Test", "TEST", 0)
	UserTeller    = Token.CallerTeller()
)

func init() {
	grc20reg.Register(cross, Token, "")
}

// Mint tokens to the specified address. Unrestricted for testing purposes.
func Mint(cur realm, to address, amount int64) {
	if err := ledger.Mint(to, amount); err != nil {
		panic(err)
	}
}

// Approve sets an allowance for spender to spend owner's tokens.
// Uses PrivateLedger directly to allow explicit owner specification.
func Approve(cur realm, owner, spender address, amount int64) {
	if err := ledger.Approve(owner, spender, amount); err != nil {
		panic(err)
	}
}

func BalanceOf(addr address) int64 {
	return UserTeller.BalanceOf(addr)
}

func TotalSupply() int64 {
	return UserTeller.TotalSupply()
}

func Allowance(owner, spender address) int64 {
	return UserTeller.Allowance(owner, spender)
}
