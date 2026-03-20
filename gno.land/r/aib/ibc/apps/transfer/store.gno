package transfer

import (
	"chain"
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/demo/defi/grc20reg"
)

var (
	denoms        *avl.Tree // ibcDenom:Denom
	totalEscrow   *avl.Tree // denom:chain.Coin
	voucherTokens *avl.Tree // ibcDenom:*grc20Instance
)

// grc20Instance holds a GRC20 token and its private ledger for mint/burn.
type grc20Instance struct {
	token  *grc20.Token
	ledger *grc20.PrivateLedger
}

func init() {
	denoms = avl.NewTree()
	totalEscrow = avl.NewTree()
	voucherTokens = avl.NewTree()
}

func hasDenom(voucherDenom string) bool {
	return denoms.Has(voucherDenom)
}

func setDenom(denom Denom) {
	denoms.Set(denom.IBCDenom(), denom)
}

func getDenom(ibcDenom string) (Denom, bool) {
	x, found := denoms.Get(ibcDenom)
	if !found {
		return Denom{}, false
	}
	return x.(Denom), true
}

func addEscrowForDenom(c chain.Coin) {
	x, found := totalEscrow.Get(c.Denom)
	if found {
		c = x.(chain.Coin).Add(c)
	}
	totalEscrow.Set(c.Denom, c)
}

func subEscrowForDenom(c chain.Coin) {
	x, found := totalEscrow.Get(c.Denom)
	if !found {
		x = chain.Coin{Denom: c.Denom}
	}
	c = x.(chain.Coin).Sub(c)
	totalEscrow.Set(c.Denom, c)
}

// getOrCreateGRC20 returns the existing GRC20 instance for the given IBC
// denom, or creates a new one and registers it in grc20reg for DeFi
// discoverability.
func getOrCreateGRC20(baseDenom, voucherDenom string) *grc20Instance {
	if v, ok := voucherTokens.Get(voucherDenom); ok {
		return v.(*grc20Instance)
	}
	token, ledger := grc20.NewToken(baseDenom, voucherDenom, 0)
	inst := &grc20Instance{token: token, ledger: ledger}
	voucherTokens.Set(voucherDenom, inst)
	grc20reg.Register(cross, token, voucherDenom)
	return inst
}

// getGRC20 returns the GRC20 instance for the given IBC denom, or nil if not
// found.
func getGRC20(ibcDenom string) *grc20Instance {
	v, ok := voucherTokens.Get(ibcDenom)
	if !ok {
		return nil
	}
	return v.(*grc20Instance)
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

// GRC20Alias returns a slash-free alias for a GRC20 denom (grc20reg key)
// by replacing "/" with ":". Colons are allowed in Cosmos SDK denoms but
// never appear in grc20reg keys (Gno package paths), so no escaping is needed.
// Example: "gno.land/r/demo/foo.FOO" → "gno.land:r:demo:foo.FOO"
func GRC20Alias(grc20regKey string) string {
	return strings.ReplaceAll(grc20regKey, "/", ":")
}

// resolveGRC20Alias converts a GRC20 alias back to the grc20reg key
// by replacing ":" with "/".
func resolveGRC20Alias(alias string) string {
	return strings.ReplaceAll(alias, ":", "/")
}

// isGRC20Alias returns true if the denom is a GRC20 alias.
// GRC20 aliases always start with "gno.land:" (the colon-encoded form of "gno.land/").
func isGRC20Alias(denom string) bool {
	return strings.HasPrefix(denom, "gno.land:")
}
