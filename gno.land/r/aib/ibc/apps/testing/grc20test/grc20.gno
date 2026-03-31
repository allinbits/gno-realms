// Package grc20test provides a test GRC20 token for IBC transfer testing.
package grc20test

import (
	"gno.land/p/demo/tokens/grc20"
	"gno.land/r/demo/defi/grc20reg"
)

// Slug is the grc20reg registration slug (the third argument to
// grc20reg.Register). It deliberately contains colons, slashes, and a literal
// %2F to stress-test the GRC20Alias url.PathEscape encoding used in IBC transfer
// packets.
const Slug = "my:exotic/slug%2F"

var (
	Token, ledger = grc20.NewToken("Test", "TEST", 0)
	UserTeller    = Token.CallerTeller()
)

func init() {
	grc20reg.Register(cross, Token, Slug)
}

// Mint tokens to the specified address.
// WARNING: test-only, no caller authorization — do not use as a pattern for production.
func Mint(cur realm, to address, amount int64) {
	if err := ledger.Mint(to, amount); err != nil {
		panic(err)
	}
}

// Approve sets an allowance for spender to spend owner's tokens.
// Uses PrivateLedger directly to allow explicit owner specification.
// WARNING: test-only, no caller authorization — do not use as a pattern for production.
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
