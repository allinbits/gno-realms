package transfer

import (
	"chain"
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/demo/defi/grc20reg"
)

var (
	denoms        *bptree.BPTree // ibcDenom:Denom
	totalEscrow   *bptree.BPTree // denom:chain.Coin
	voucherTokens *bptree.BPTree // ibcDenom:*voucher
)

// voucher holds a voucher token and its private ledger for mint/burn.
type voucher struct {
	token  *grc20.Token
	ledger *grc20.PrivateLedger
}

func init() {
	denoms = bptree.NewBPTree32()
	totalEscrow = bptree.NewBPTree32()
	voucherTokens = bptree.NewBPTree32()
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

// getOrCreateVoucher returns the existing voucher instance for the given IBC
// denom, or creates a new one and registers it in grc20reg for DeFi
// discoverability. Non-crossing helper; rlm is needed to issue the cross
// call into grc20reg.Register from this realm's frame.
//
// The GRC20 symbol is derived from a short prefix of the IBC hash. We can't
// use the full voucherDenom ("ibc/<64-hex-hash>") because v2 grc20 enforces
// MaxSymbolLen=11 and [A-Za-z0-9_-] only — the "/" alone disqualifies it. The
// grc20reg slug stays the full hash (collision-safe across vouchers); the
// symbol is purely the display token symbol and an 8-char hex prefix is
// collision-resistant enough for that purpose. Name remains the base denom.
func getOrCreateVoucher(_ int, rlm realm, baseDenom, voucherDenom string) *voucher {
	if v, ok := voucherTokens.Get(voucherDenom); ok {
		return v.(*voucher)
	}
	hash := voucherDenom[len("ibc/"):]
	symbol := hash
	if len(symbol) > 11 {
		symbol = symbol[:11]
	}
	token, ledger := grc20.NewToken(0, rlm, baseDenom, symbol, 0)
	inst := &voucher{token: token, ledger: ledger}
	voucherTokens.Set(voucherDenom, inst)
	// Slug = full hash, unique per voucher.
	grc20reg.Register(cross(rlm), token, hash)
	return inst
}

// getVoucher returns the voucher instance for the given IBC denom, or nil if not
// found.
func getVoucher(ibcDenom string) *voucher {
	v, ok := voucherTokens.Get(ibcDenom)
	if !ok {
		return nil
	}
	return v.(*voucher)
}

// VoucherBalanceOf returns the balance of a voucher token for a given address.
// Returns 0 if the token does not exist.
func VoucherBalanceOf(ibcDenom string, addr address) int64 {
	inst := getVoucher(ibcDenom)
	if inst == nil {
		return 0
	}
	return inst.token.BalanceOf(addr)
}

// GRC20Alias returns a slash-free alias for a GRC20 denom (grc20reg key)
// by replacing "/" with ":". This is safe because grc20reg slugs are
// alphanumeric (enforced by grc20reg.Register), so colons never appear in
// grc20reg keys, making the replacement reversible.
// Examples:
//
//	"gno.land/r/demo/foo"      → "gno.land:r:demo:foo"
//	"gno.land/r/demo/foo.FOO"  → "gno.land:r:demo:foo.FOO"
func GRC20Alias(grc20regKey string) string {
	return strings.ReplaceAll(grc20regKey, "/", ":")
}

// resolveGRC20Alias converts a GRC20 alias back to the grc20reg key
// by replacing ":" with "/".
func resolveGRC20Alias(alias string) string {
	return strings.ReplaceAll(alias, ":", "/")
}

// isGRC20Alias returns true if the denom is a GRC20 alias.
// GRC20 aliases always start with "gno.land:" (the colon form of "gno.land/").
func isGRC20Alias(denom string) bool {
	return strings.HasPrefix(denom, "gno.land:")
}
