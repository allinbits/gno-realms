package transfer

import (
	"chain"
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/demo/defi/grc20reg"
)

var (
	denoms        *bptree.BPTree // ibcDenom:Denom
	totalEscrow   *bptree.BPTree // denom:chain.Coin
	voucherTokens *bptree.BPTree // ibcDenom:*voucher

	// nextVoucherID allocates a unique grc20 token id for each voucher. Voucher
	// symbols are truncated IBC-hash prefixes that can collide, so a shared
	// monotonic id keeps every token's grc20 identifier distinct.
	nextVoucherID seqid.ID
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
	d := denoms.Get(ibcDenom)
	if d == nil {
		return Denom{}, false
	}
	return d.(Denom), true
}

func addEscrowForDenom(c chain.Coin) {
	d := totalEscrow.Get(c.Denom)
	if d != nil {
		c = d.(chain.Coin).Add(c)
	}
	totalEscrow.Set(c.Denom, c)
}

func subEscrowForDenom(c chain.Coin) {
	x := totalEscrow.Get(c.Denom)
	if x == nil {
		x = chain.Coin{Denom: c.Denom}
	}
	c = x.(chain.Coin).Sub(c)
	totalEscrow.Set(c.Denom, c)
}

// VoucherSymbol returns the grc20 token symbol for an IBC voucher denom: the IBC
// hash truncated to grc20's MaxSymbolLen. The full voucherDenom ("ibc/<64-hex-
// hash>") can't be a symbol because v2 grc20 enforces MaxSymbolLen and
// [A-Za-z0-9_-] only. Since grc20reg keys tokens by rlmpath.symbol, this is also
// the symbol component of a voucher's registry key, so callers locate a voucher
// via grc20reg.Get(<this realm's pkgpath> + "." + VoucherSymbol(ibcDenom)).
func VoucherSymbol(ibcDenom string) string {
	symbol := strings.TrimPrefix(ibcDenom, "ibc/")
	if len(symbol) > grc20.MaxSymbolLen {
		symbol = symbol[:grc20.MaxSymbolLen]
	}
	return symbol
}

// getOrCreateVoucher returns the existing voucher instance for the given IBC
// denom, or creates a new one and registers it in grc20reg for DeFi
// discoverability. Non-crossing helper; rlm is needed to issue the cross
// call into grc20reg.Register from this realm's frame.
//
// The token symbol is a truncated IBC hash (see VoucherSymbol); its name is the
// base denom, and nextVoucherID keeps each token's grc20 id distinct. grc20reg
// keys the token by rlmpath.symbol (not the slug), so the full-hash slug is
// retained only as event metadata. Because the key is the truncated symbol,
// two vouchers whose hashes share an 11-char prefix would collide on the
// registry key (astronomically unlikely, but no longer guarded by the slug).
func getOrCreateVoucher(_ int, rlm realm, baseDenom, voucherDenom string) *voucher {
	if v := voucherTokens.Get(voucherDenom); v != nil {
		return v.(*voucher)
	}
	token, ledger := grc20.NewToken(baseDenom, VoucherSymbol(voucherDenom), 0, nextVoucherID.Next(), rlm)
	inst := &voucher{token: token, ledger: ledger}
	voucherTokens.Set(voucherDenom, inst)
	grc20reg.Register(cross(rlm), token, voucherDenom[len("ibc/"):])
	return inst
}

// getVoucher returns the voucher instance for the given IBC denom, or nil if not
// found.
func getVoucher(ibcDenom string) *voucher {
	v := voucherTokens.Get(ibcDenom)
	if v == nil {
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
