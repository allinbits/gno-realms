// Package grc20test provides a test GRC20 token for IBC transfer testing.
package grc20test

import (
	"gno.land/p/nt/grc20/v1"
	"gno.land/r/nt/grc20reg/v1"
)

// Slug is the grc20reg registration slug (the third argument to
// grc20reg.Register). Slugs must be alphanumeric (enforced by grc20reg).
const Slug = "TEST"

// Token, ledger, and UserTeller are initialised in init(cur realm) because
// grc20.NewToken now requires a `realm` capability and there is no realm
// value available at package-level var init time.
var (
	Token      *grc20.Token
	ledger     *grc20.PrivateLedger
	UserTeller grc20.Teller
)

func init(cur realm) {
	Token, ledger = grc20.NewToken("Test", "TEST", 0, 0, cur)
	UserTeller = ledger.CallerTeller()
	grc20reg.Register(cross(cur), Token, Slug)
}

// Mint tokens to the specified address.
// WARNING: test-only, no caller authorization — do not use as a pattern for production.
func Mint(cur realm, to address, amount uint256) {
	if err := ledger.Mint(to, amount); err != nil {
		panic(err)
	}
}

// Approve sets an allowance for spender to spend owner's tokens.
// Uses PrivateLedger directly to allow explicit owner specification.
// WARNING: test-only, no caller authorization — do not use as a pattern for production.
func Approve(cur realm, owner, spender address, amount uint256) {
	if err := ledger.Approve(owner, spender, amount); err != nil {
		panic(err)
	}
}

func BalanceOf(addr address) uint256 {
	return UserTeller.BalanceOf(addr)
}

func TotalSupply() uint256 {
	return UserTeller.TotalSupply()
}

func Allowance(owner, spender address) uint256 {
	return UserTeller.Allowance(owner, spender)
}
