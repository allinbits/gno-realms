package transfer

import (
	"chain"
	"strconv"

	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc20/v1"
	"gno.land/p/nt/ufmt/v0"
)

// sandboxStore is the Store a candidate implementation is built against in
// the upgrade preflight (CheckUpdateImpl): empty, holding no live object and
// no reference to this realm's state, every read answering nothing and every
// write refused. The live store reaches candidate code only in an authorized
// installation.
type sandboxStore struct{}

var _ Store = sandboxStore{}

func refuseSandbox() {
	panic("transfer: the preflight's sandbox store holds nothing and takes no write")
}

func emptyTree() bptree.ITree { return readOnlyTree{t: bptree.NewBPTree32()} }

func (sandboxStore) HasDenom(string) bool                     { return false }
func (sandboxStore) Denom(string) (ics20.Denom, bool)         { return ics20.Denom{}, false }
func (sandboxStore) SetDenom(_ int, rlm realm, d ics20.Denom) { refuseSandbox() }
func (sandboxStore) Denoms() bptree.ITree                     { return emptyTree() }

func (sandboxStore) AddEscrow(_ int, rlm realm, clientID, denom string, amount uint256) {
	refuseSandbox()
}
func (sandboxStore) CheckEscrow(clientID, denom string, amount uint256) error {
	return ufmt.Errorf("insufficient escrow for client %s denom %s: have 0, want %s", clientID, denom, strconv.FormatUint256(amount, 10))
}
func (sandboxStore) IterateEscrow(fn func(clientID, denom string, amount uint256) bool) {}
func (sandboxStore) Escrowed(clientID, denom string) uint256                            { return 0 }

func (sandboxStore) EscrowGRC20(_ int, rlm realm, clientID, denomKey string, from address, amount uint256) error {
	refuseSandbox()
	return nil
}
func (sandboxStore) UnescrowGRC20(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error {
	refuseSandbox()
	return nil
}
func (sandboxStore) UnescrowNative(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error {
	refuseSandbox()
	return nil
}

func (sandboxStore) VoucherToken(string) *grc20.Token { return nil }
func (sandboxStore) Vouchers() bptree.ITree           { return emptyTree() }
func (sandboxStore) GetOrCreateVoucher(_ int, rlm realm, baseDenom, voucherDenom string, decimals int) *grc20.Token {
	refuseSandbox()
	return nil
}
func (sandboxStore) MintVoucher(_ int, rlm realm, ibcDenom string, to address, amount uint256) error {
	refuseSandbox()
	return nil
}
func (sandboxStore) BurnVoucher(_ int, rlm realm, ibcDenom string, from address, amount uint256) error {
	refuseSandbox()
	return nil
}

func (sandboxStore) SetPendingNativeEscrow(_ int, rlm realm, c chain.Coin) { refuseSandbox() }
func (sandboxStore) PendingNativeEscrow() (chain.Coin, bool)               { return chain.Coin{}, false }
func (sandboxStore) SetPendingVoucherSend(_ int, rlm realm, sender, sourceClient, denom string, amount uint256) {
	refuseSandbox()
}
func (sandboxStore) ConsumePendingVoucherSend(_ int, rlm realm) (PendingSend, bool) {
	return PendingSend{}, false
}
func (sandboxStore) SetPendingGRC20Send(_ int, rlm realm, sender, sourceClient, denom string, amount uint256) {
	refuseSandbox()
}
func (sandboxStore) ConsumePendingGRC20Send(_ int, rlm realm) (PendingSend, bool) {
	return PendingSend{}, false
}

func (sandboxStore) InitExt(_ int, rlm realm, key string, ctor func() any) { refuseSandbox() }
func (sandboxStore) Ext(_ int, rlm realm, key string) any                  { refuseSandbox(); return nil }
func (sandboxStore) ExtView(key string) any                                { return nil }
