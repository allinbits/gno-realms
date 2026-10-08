package transfer

import (
	"chain"
	"chain/banker"
	"strings"

	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// The state of the transfer app lives in this realm forever (see ADR 0002):
// the escrow accounting, the known denominations, the voucher tokens with
// their mint/burn ledgers, and the sends Transfer authorizes for
// OnSendPacket. The implementation realm reads and writes it through the
// Store interface. Every mutator and every value move takes the proxy's own
// live realm value and asserts it (assertProxyRealm): the implementation is
// always invoked non-crossing by this realm, so the value it forwards is this
// realm's cur, and nobody else can present one. The value moves stay here
// because this realm is the home of the voucher tokens and the holder of the
// escrow, and because each of them keeps the escrow accounting in step with
// the balances.

// Store is the proxy-owned state and the value-moving services, as seen by an
// implementation.
type Store interface {
	// Denominations known to this chain (minted vouchers), keyed by IBC denom.
	HasDenom(ibcDenom string) bool
	Denom(ibcDenom string) (ics20.Denom, bool)
	SetDenom(_ int, rlm realm, d ics20.Denom)
	// Denoms is a read-only view; values are ics20.Denom.
	Denoms() bptree.ITree

	// Escrow accounting per (client, denom). AddEscrow records coins that
	// already landed at this realm (a native transfer); the GRC20 and
	// release paths below keep the accounting in step with the moves.
	AddEscrow(_ int, rlm realm, clientID string, c chain.Coin)
	CheckEscrow(clientID string, c chain.Coin) error
	// IterateEscrow walks the accounting, clients in key order and their
	// denoms in key order, until fn returns true.
	IterateEscrow(fn func(clientID string, c chain.Coin) bool)

	// EscrowGRC20 moves c from `from` to this realm (TransferFrom, so the
	// owner must have approved this realm) and records it under clientID.
	EscrowGRC20(_ int, rlm realm, clientID, denomKey string, from address, c chain.Coin) error
	// UnescrowGRC20 and UnescrowNative release c to receiver out of what
	// clientID escrowed: check, move, then debit.
	UnescrowGRC20(_ int, rlm realm, clientID, receiver string, c chain.Coin) error
	UnescrowNative(_ int, rlm realm, clientID, receiver string, c chain.Coin) error

	// Vouchers: the tokens and their ledgers never leave this realm.
	VoucherToken(ibcDenom string) *grc20.Token
	// Vouchers is a read-only view; values are *grc20.Token.
	Vouchers() bptree.ITree
	GetOrCreateVoucher(_ int, rlm realm, baseDenom, voucherDenom string) *grc20.Token
	MintVoucher(_ int, rlm realm, ibcDenom string, to address, amount int64) error
	BurnVoucher(_ int, rlm realm, ibcDenom string, from address, amount int64) error

	// The sends Transfer authorizes for OnSendPacket. Transfer clears them on
	// every exit path (see transfer.gno); the Consume* readers clear their
	// slot as well.
	SetPendingNativeEscrow(_ int, rlm realm, c chain.Coin)
	PendingNativeEscrow() (chain.Coin, bool)
	SetPendingVoucherSend(_ int, rlm realm, sender, sourceClient, denom string, amount int64)
	ConsumePendingVoucherSend(_ int, rlm realm) (PendingSend, bool)
	SetPendingGRC20Send(_ int, rlm realm, sender, sourceClient, denom string, amount int64)
	ConsumePendingGRC20Send(_ int, rlm realm) (PendingSend, bool)
}

// PendingSend records the token send that Transfer authorized for
// OnSendPacket: the EOA that signed, the client, the denom path and the
// amount the packet must carry.
type PendingSend struct {
	Sender       string
	SourceClient string
	Denom        string
	Amount       int64
}

var (
	denoms        *bptree.BPTree // ibcDenom:ics20.Denom
	totalEscrow   *bptree.BPTree // clientID:*bptree.BPTree(denom:chain.Coin)
	voucherTokens *bptree.BPTree // ibcDenom:*voucher

	// nextVoucherID allocates a unique grc20 token id for each voucher. Voucher
	// symbols are truncated IBC-hash prefixes that can collide, so a shared
	// monotonic id keeps every token's grc20 identifier distinct.
	nextVoucherID seqid.ID

	// Gno persists package-level vars to the realm store at end of tx. These
	// pending values are cleared before Transfer returns (its defer) so a
	// leftover never bleeds into a later tx.
	//
	// pendingNativeEscrow is set by the native branch of Transfer and read by
	// OnSendPacket. It bridges the user-call boundary check, which is only
	// possible in Transfer where PreviousRealm() is the EOA, to the escrow
	// accounting done in OnSendPacket.
	pendingNativeEscrow *chain.Coin
	// pendingVoucherSend and pendingGRC20Send are set by the voucher and
	// GRC20 branches of Transfer after the direct user-call guard passes.
	// OnSendPacket consumes them before burning or escrowing user-owned
	// tokens, preventing direct core.SendPacket bypasses and binding the
	// packet to the asset the user explicitly requested.
	pendingVoucherSend *PendingSend
	pendingGRC20Send   *PendingSend
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

// transferStore implements Store over the package-level state.
type transferStore struct{}

var (
	_     Store = transferStore{}
	store Store = transferStore{}
)

func (transferStore) HasDenom(ibcDenom string) bool { return hasDenom(ibcDenom) }

func (transferStore) Denom(ibcDenom string) (ics20.Denom, bool) { return getDenom(ibcDenom) }

func (transferStore) SetDenom(_ int, rlm realm, d ics20.Denom) {
	assertProxyRealm(0, rlm)
	setDenom(d)
}

func (transferStore) Denoms() bptree.ITree { return readOnlyTree{t: denoms} }

func (transferStore) AddEscrow(_ int, rlm realm, clientID string, c chain.Coin) {
	assertProxyRealm(0, rlm)
	addEscrowForClient(clientID, c)
}

func (transferStore) CheckEscrow(clientID string, c chain.Coin) error {
	return checkEscrowForClient(clientID, c)
}

func (transferStore) IterateEscrow(fn func(clientID string, c chain.Coin) bool) {
	totalEscrow.IterateByOffset(0, totalEscrow.Size(), func(clientID string, v any) bool {
		t := v.(*bptree.BPTree)
		stop := false
		t.IterateByOffset(0, t.Size(), func(_ string, cv any) bool {
			stop = fn(clientID, cv.(chain.Coin))
			return stop
		})
		return stop
	})
}

func (transferStore) EscrowGRC20(_ int, rlm realm, clientID, denomKey string, from address, c chain.Coin) error {
	assertProxyRealm(0, rlm)
	token := grc20reg.Get(denomKey)
	if token == nil {
		return ufmt.Errorf("GRC20 token %s not found in grc20reg", denomKey)
	}
	teller := token.RealmTeller(0, rlm)
	if err := teller.TransferFrom(0, rlm, from, rlm.Address(), c.Amount); err != nil {
		return ufmt.Errorf("escrow GRC20 %s error: %v", denomKey, err)
	}
	addEscrowForClient(clientID, c)
	return nil
}

func (transferStore) UnescrowGRC20(_ int, rlm realm, clientID, receiver string, c chain.Coin) error {
	assertProxyRealm(0, rlm)
	return unescrowGRC20(0, rlm, clientID, receiver, c)
}

func (transferStore) UnescrowNative(_ int, rlm realm, clientID, receiver string, c chain.Coin) error {
	assertProxyRealm(0, rlm)
	return unescrowNative(0, rlm, clientID, receiver, c)
}

func (transferStore) VoucherToken(ibcDenom string) *grc20.Token {
	inst := getVoucher(ibcDenom)
	if inst == nil {
		return nil
	}
	return inst.token
}

func (transferStore) Vouchers() bptree.ITree {
	return readOnlyTree{t: voucherTokens, mapValue: func(v any) any { return v.(*voucher).token }}
}

func (transferStore) GetOrCreateVoucher(_ int, rlm realm, baseDenom, voucherDenom string) *grc20.Token {
	assertProxyRealm(0, rlm)
	return getOrCreateVoucher(0, rlm, baseDenom, voucherDenom).token
}

func (transferStore) MintVoucher(_ int, rlm realm, ibcDenom string, to address, amount int64) error {
	assertProxyRealm(0, rlm)
	inst := getVoucher(ibcDenom)
	if inst == nil {
		return ufmt.Errorf("voucher token not found for denom %s", ibcDenom)
	}
	return inst.ledger.Mint(to, amount)
}

func (transferStore) BurnVoucher(_ int, rlm realm, ibcDenom string, from address, amount int64) error {
	assertProxyRealm(0, rlm)
	inst := getVoucher(ibcDenom)
	if inst == nil {
		return ufmt.Errorf("voucher token not found for denom %s", ibcDenom)
	}
	return inst.ledger.Burn(from, amount)
}

func (transferStore) SetPendingNativeEscrow(_ int, rlm realm, c chain.Coin) {
	assertProxyRealm(0, rlm)
	pendingNativeEscrow = &c
}

func (transferStore) PendingNativeEscrow() (chain.Coin, bool) {
	if pendingNativeEscrow == nil {
		return chain.Coin{}, false
	}
	return *pendingNativeEscrow, true
}

func (transferStore) SetPendingVoucherSend(_ int, rlm realm, sender, sourceClient, denom string, amount int64) {
	assertProxyRealm(0, rlm)
	pendingVoucherSend = &PendingSend{Sender: sender, SourceClient: sourceClient, Denom: denom, Amount: amount}
}

func (transferStore) ConsumePendingVoucherSend(_ int, rlm realm) (PendingSend, bool) {
	assertProxyRealm(0, rlm)
	if pendingVoucherSend == nil {
		return PendingSend{}, false
	}
	ps := *pendingVoucherSend
	pendingVoucherSend = nil
	return ps, true
}

func (transferStore) SetPendingGRC20Send(_ int, rlm realm, sender, sourceClient, denom string, amount int64) {
	assertProxyRealm(0, rlm)
	pendingGRC20Send = &PendingSend{Sender: sender, SourceClient: sourceClient, Denom: denom, Amount: amount}
}

func (transferStore) ConsumePendingGRC20Send(_ int, rlm realm) (PendingSend, bool) {
	assertProxyRealm(0, rlm)
	if pendingGRC20Send == nil {
		return PendingSend{}, false
	}
	ps := *pendingGRC20Send
	pendingGRC20Send = nil
	return ps, true
}

// clearPendingSends drops whatever Transfer authorized for the current call.
func clearPendingSends() {
	pendingNativeEscrow = nil
	pendingVoucherSend = nil
	pendingGRC20Send = nil
}

// readOnlyTree is the view of a proxy-owned B+ tree handed to the
// implementation for rendering. Handing the tree itself would hand a write
// capability (a /p/ method on a foreign receiver runs with the receiver's
// storage authority), and the voucher tree holds the mint/burn ledgers, so
// mapValue substitutes the token for the voucher entry. The view implements
// bptree.ITree, which jsonpage paginates, and panics on the mutators.
type readOnlyTree struct {
	t        *bptree.BPTree
	mapValue func(any) any
}

var _ bptree.ITree = readOnlyTree{}

func (r readOnlyTree) value(v any) any {
	if v == nil || r.mapValue == nil {
		return v
	}
	return r.mapValue(v)
}

func (r readOnlyTree) wrap(cb bptree.IterCbFn) bptree.IterCbFn {
	return func(k string, v any) bool { return cb(k, r.value(v)) }
}

func (r readOnlyTree) Size() int           { return r.t.Size() }
func (r readOnlyTree) Has(key string) bool { return r.t.Has(key) }
func (r readOnlyTree) Get(key string) any  { return r.value(r.t.Get(key)) }
func (r readOnlyTree) GetByIndex(i int) (string, any) {
	k, v := r.t.GetByIndex(i)
	return k, r.value(v)
}
func (r readOnlyTree) Iterate(start, end string, cb bptree.IterCbFn) bool {
	return r.t.Iterate(start, end, r.wrap(cb))
}
func (r readOnlyTree) ReverseIterate(start, end string, cb bptree.IterCbFn) bool {
	return r.t.ReverseIterate(start, end, r.wrap(cb))
}
func (r readOnlyTree) IterateByOffset(offset, count int, cb bptree.IterCbFn) bool {
	return r.t.IterateByOffset(offset, count, r.wrap(cb))
}
func (r readOnlyTree) ReverseIterateByOffset(offset, count int, cb bptree.IterCbFn) bool {
	return r.t.ReverseIterateByOffset(offset, count, r.wrap(cb))
}
func (readOnlyTree) Set(string, any) bool      { panic("transfer: read-only tree") }
func (readOnlyTree) Remove(string) (any, bool) { panic("transfer: read-only tree") }

// escrowForClient returns the per-client denom->coin tree, creating it on first
// access. Escrow is accounted per (client, denom) so a malicious client cannot
// release funds escrowed under a different client (see shared-escrow drain).
func escrowForClient(clientID string) *bptree.BPTree {
	t := getEscrowForClient(clientID)
	if t == nil {
		t = bptree.NewBPTree32()
		totalEscrow.Set(clientID, t)
	}
	return t
}

// getEscrowForClient returns the per-client tree without creating it. Returns
// nil if clientID has never escrowed anything. Used by read-only paths
// (checkEscrowForClient, rendering) so a query for an unknown client doesn't
// allocate an empty entry in totalEscrow.
func getEscrowForClient(clientID string) *bptree.BPTree {
	v := totalEscrow.Get(clientID)
	if v == nil {
		return nil
	}
	return v.(*bptree.BPTree)
}

// addEscrowForClient records coins escrowed under clientID. Used when this chain
// sends tokens over clientID (OnSendPacket); the matching release can only come
// back through the same client.
func addEscrowForClient(clientID string, c chain.Coin) {
	t := escrowForClient(clientID)
	if x := t.Get(c.Denom); x != nil {
		c = x.(chain.Coin).Add(c)
	}
	t.Set(c.Denom, c)
}

// checkEscrowForClient verifies clientID locked enough of c.Denom, without
// mutating the accounting. Read-only so callers can move tokens between the
// check and the debit (see unescrowGRC20/unescrowNative).
func checkEscrowForClient(clientID string, c chain.Coin) error {
	t := getEscrowForClient(clientID)
	if t == nil {
		return ufmt.Errorf("insufficient escrow for client %s denom %s: have 0, want %d", clientID, c.Denom, c.Amount)
	}
	x := t.Get(c.Denom)
	if x == nil {
		return ufmt.Errorf("insufficient escrow for client %s denom %s: have 0, want %d", clientID, c.Denom, c.Amount)
	}
	have := x.(chain.Coin)
	if have.Amount < c.Amount {
		return ufmt.Errorf("insufficient escrow for client %s denom %s: have %d, want %d", clientID, c.Denom, have.Amount, c.Amount)
	}
	return nil
}

// debitEscrowForClient subtracts c from clientID's balance. Assumes
// checkEscrowForClient already passed.
func debitEscrowForClient(clientID string, c chain.Coin) {
	t := escrowForClient(clientID)
	x := t.Get(c.Denom)
	have := x.(chain.Coin)
	t.Set(c.Denom, chain.NewCoin(c.Denom, have.Amount-c.Amount))
}

// unescrowGRC20 returns escrowed GRC20 tokens to receiver. The check runs
// before the transfer (per-client drain defense), the debit only after a
// successful transfer: OnRecvPacket returning Failure does not roll back realm
// store writes (IBCApp contract), so debiting first would lock the funds on a
// transfer failure.
func unescrowGRC20(_ int, rlm realm, clientID, receiver string, coin chain.Coin) error {
	denomKey := ResolveGRC20Alias(coin.Denom)
	token := grc20reg.Get(denomKey)
	if token == nil {
		return ufmt.Errorf("GRC20 token %s not found in grc20reg", denomKey)
	}
	if err := checkEscrowForClient(clientID, coin); err != nil {
		return err
	}
	teller := token.RealmTeller(0, rlm)
	if err := teller.Transfer(0, rlm, address(receiver), coin.Amount); err != nil {
		return ufmt.Errorf("unescrow GRC20 %s error: %v", denomKey, err)
	}
	debitEscrowForClient(clientID, coin)
	return nil
}

// unescrowNative returns escrowed native coins to receiver. Same
// check-before-mutate ordering as unescrowGRC20: banker.SendCoins has no error
// return, but keeping the debit after the send avoids a lost-debit if that ever
// changes. Per-client isolation is enforced by checkEscrowForClient's
// accounting, not the banker, since the realm holds a single physical escrow
// account (no per-client addresses in Gno).
func unescrowNative(_ int, rlm realm, clientID, receiver string, coin chain.Coin) error {
	if err := checkEscrowForClient(clientID, coin); err != nil {
		return err
	}
	var (
		// TODO no app/clientID specific escrow address ?
		from   = rlm.Address()
		to     = address(receiver)
		amount = chain.NewCoins(coin)
		banker = banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	)
	banker.SendCoins(from, to, amount)
	debitEscrowForClient(clientID, coin)
	return nil
}

func hasDenom(voucherDenom string) bool {
	return denoms.Has(voucherDenom)
}

func setDenom(denom ics20.Denom) {
	denoms.Set(denom.IBCDenom(), denom)
}

func getDenom(ibcDenom string) (ics20.Denom, bool) {
	d := denoms.Get(ibcDenom)
	if d == nil {
		return ics20.Denom{}, false
	}
	return d.(ics20.Denom), true
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

// ResolveGRC20Alias converts a GRC20 alias back to the grc20reg key
// by replacing ":" with "/".
func ResolveGRC20Alias(alias string) string {
	return strings.ReplaceAll(alias, ":", "/")
}

// IsGRC20Alias returns true if the denom is a GRC20 alias.
// GRC20 aliases always start with "gno.land:" (the colon form of "gno.land/").
func IsGRC20Alias(denom string) bool {
	return strings.HasPrefix(denom, "gno.land:")
}
