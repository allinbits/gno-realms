package transfer

import (
	"chain"
	"chain/banker"
	"math"
	"math/overflow"
	"strconv"
	"strings"

	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc20/v1"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v1"
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
//
// Amounts are uint256, the range of an ICS20 amount on the wire and of a
// grc20 v1 token (ADR pr6375 R15; gno ADR pr6387, pr6388): vouchers and
// GRC20 escrow count in it exactly. Native coins stay int64, so the two
// native paths convert at the boundary: a coin that landed here widens
// (CoinAmount), and a release is refused above math.MaxInt64 (coinOf), which
// the escrow invariant never reaches for a native denom.

// Store is the proxy-owned state and the value-moving services, as seen by an
// implementation.
type Store interface {
	// Denominations known to this chain (minted vouchers), keyed by IBC denom.
	HasDenom(ibcDenom string) bool
	Denom(ibcDenom string) (ics20.Denom, bool)
	SetDenom(_ int, rlm realm, d ics20.Denom)
	// Denoms is a read-only view; values are ics20.Denom.
	Denoms() bptree.ITree

	// Escrow accounting per (client, denom), in base units. AddEscrow
	// records value that already landed at this realm (a native transfer);
	// the GRC20 and release paths below keep the accounting in step with
	// the moves.
	AddEscrow(_ int, rlm realm, clientID, denom string, amount uint256)
	CheckEscrow(clientID, denom string, amount uint256) error
	// IterateEscrow walks the accounting, clients in key order and their
	// denoms in key order, until fn returns true.
	IterateEscrow(fn func(clientID, denom string, amount uint256) bool)
	// Escrowed is the amount of denom accounted to clientID (a client id, or
	// the route key of a controlled route), 0 if none.
	Escrowed(clientID, denom string) uint256

	// EscrowGRC20 moves amount of the grc20reg token denomKey from `from` to
	// this realm (TransferFrom, so the owner must have approved this realm)
	// and records it under clientID as the token's alias (GRC20Alias).
	EscrowGRC20(_ int, rlm realm, clientID, denomKey string, from address, amount uint256) error
	// UnescrowGRC20 and UnescrowNative release amount of denom (a GRC20
	// alias, or a native coin denom) to receiver out of what clientID
	// escrowed: check, move, then debit. A native amount above
	// math.MaxInt64 is refused: no coin holds it.
	UnescrowGRC20(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error
	UnescrowNative(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error

	// Vouchers: the tokens and their ledgers never leave this realm.
	VoucherToken(ibcDenom string) *grc20.Token
	// Vouchers is a read-only view; values are *grc20.Token.
	Vouchers() bptree.ITree
	GetOrCreateVoucher(_ int, rlm realm, baseDenom, voucherDenom string) *grc20.Token
	MintVoucher(_ int, rlm realm, ibcDenom string, to address, amount uint256) error
	BurnVoucher(_ int, rlm realm, ibcDenom string, from address, amount uint256) error

	// The sends Transfer authorizes for OnSendPacket. Transfer clears them on
	// every exit path (see transfer.gno); the Consume* readers clear their
	// slot as well.
	SetPendingNativeEscrow(_ int, rlm realm, c chain.Coin)
	PendingNativeEscrow() (chain.Coin, bool)
	SetPendingVoucherSend(_ int, rlm realm, sender, sourceClient, denom string, amount uint256)
	ConsumePendingVoucherSend(_ int, rlm realm) (PendingSend, bool)
	SetPendingGRC20Send(_ int, rlm realm, sender, sourceClient, denom string, amount uint256)
	ConsumePendingGRC20Send(_ int, rlm realm) (PendingSend, bool)

	// Extension state: values an implementation keeps in this realm under a
	// key, beside the frozen state above (the Ethereum route controls of
	// ADR pr6375 §7). InitExt stores ctor() under key once, calling ctor here
	// so the value is allocated in this realm: ctor must be a /p/-declared
	// top-level function (as for core.Store.AddClient). Ext returns the
	// stored value, mutable, to the implementation only. ExtView returns its
	// read-only view (the value's ReadOnly() result), which anyone may read.
	InitExt(_ int, rlm realm, key string, ctor func() any)
	Ext(_ int, rlm realm, key string) any
	ExtView(key string) any
}

// ReadOnlyer is implemented by extension values: ReadOnly returns a view
// that exposes no mutator, which ExtView hands to anyone.
type ReadOnlyer interface {
	ReadOnly() any
}

// PendingSend records the token send that Transfer authorized for
// OnSendPacket: the EOA that signed, the client, the denom path and the
// amount the packet must carry.
type PendingSend struct {
	Sender       string
	SourceClient string
	Denom        string
	Amount       uint256
}

var (
	denoms        *bptree.BPTree // ibcDenom:ics20.Denom
	totalEscrow   *bptree.BPTree // clientID:*bptree.BPTree(denom:uint256)
	voucherTokens *bptree.BPTree // ibcDenom:*voucher

	// nextVoucherID allocates a unique grc20 token id for each voucher, and
	// with it the voucher's symbol (see VoucherSymbol).
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
	// ext holds the implementations' extension state (see Store.InitExt).
	ext = bptree.NewBPTree32() // key -> value

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
	symbol string // its grc20 symbol and registry key's symbol, allocated once
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

func (transferStore) AddEscrow(_ int, rlm realm, clientID, denom string, amount uint256) {
	assertProxyRealm(0, rlm)
	addEscrowForClient(clientID, denom, amount)
}

func (transferStore) CheckEscrow(clientID, denom string, amount uint256) error {
	return checkEscrowForClient(clientID, denom, amount)
}

func (transferStore) IterateEscrow(fn func(clientID, denom string, amount uint256) bool) {
	totalEscrow.IterateByOffset(0, totalEscrow.Size(), func(clientID string, v any) bool {
		t := v.(*bptree.BPTree)
		stop := false
		t.IterateByOffset(0, t.Size(), func(denom string, cv any) bool {
			stop = fn(clientID, denom, cv.(uint256))
			return stop
		})
		return stop
	})
}

func (transferStore) Escrowed(clientID, denom string) uint256 {
	t := getEscrowForClient(clientID)
	if t == nil {
		return 0
	}
	x := t.Get(denom)
	if x == nil {
		return 0
	}
	return x.(uint256)
}

func (transferStore) InitExt(_ int, rlm realm, key string, ctor func() any) {
	assertProxyRealm(0, rlm)
	if ext.Has(key) {
		return
	}
	if ctor == nil {
		panic("InitExt: nil constructor")
	}
	v := ctor()
	if _, ok := v.(ReadOnlyer); !ok {
		panic("InitExt: the value has no read-only view")
	}
	ext.Set(key, v)
}

func (transferStore) Ext(_ int, rlm realm, key string) any {
	assertProxyRealm(0, rlm)
	return ext.Get(key)
}

func (transferStore) ExtView(key string) any {
	v := ext.Get(key)
	if v == nil {
		return nil
	}
	return v.(ReadOnlyer).ReadOnly()
}

func (transferStore) EscrowGRC20(_ int, rlm realm, clientID, denomKey string, from address, amount uint256) error {
	assertProxyRealm(0, rlm)
	token := grc20reg.Get(denomKey)
	if token == nil {
		return ufmt.Errorf("GRC20 token %s not found in grc20reg", denomKey)
	}
	teller := token.RealmTeller(0, rlm)
	if err := teller.TransferFrom(0, rlm, from, rlm.Address(), amount); err != nil {
		return ufmt.Errorf("escrow GRC20 %s error: %v", denomKey, err)
	}
	addEscrowForClient(clientID, GRC20Alias(denomKey), amount)
	return nil
}

func (transferStore) UnescrowGRC20(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error {
	assertProxyRealm(0, rlm)
	return unescrowGRC20(0, rlm, clientID, receiver, denom, amount)
}

func (transferStore) UnescrowNative(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error {
	assertProxyRealm(0, rlm)
	return unescrowNative(0, rlm, clientID, receiver, denom, amount)
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

func (transferStore) MintVoucher(_ int, rlm realm, ibcDenom string, to address, amount uint256) error {
	assertProxyRealm(0, rlm)
	inst := getVoucher(ibcDenom)
	if inst == nil {
		return ufmt.Errorf("voucher token not found for denom %s", ibcDenom)
	}
	return inst.ledger.Mint(to, amount)
}

func (transferStore) BurnVoucher(_ int, rlm realm, ibcDenom string, from address, amount uint256) error {
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

func (transferStore) SetPendingVoucherSend(_ int, rlm realm, sender, sourceClient, denom string, amount uint256) {
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

func (transferStore) SetPendingGRC20Send(_ int, rlm realm, sender, sourceClient, denom string, amount uint256) {
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

// CoinAmount is a coin's amount as a uint256: the widening of a native coin
// that landed at this realm. A coin never holds a negative amount.
func CoinAmount(c chain.Coin) uint256 {
	if c.Amount < 0 {
		panic("transfer: a negative coin amount")
	}
	return uint256(c.Amount)
}

// coinOf is amount of denom as a coin: refused above math.MaxInt64, the most
// a coin holds. A native denom's escrow is made of coins, so a release within
// it always fits; the check keeps the conversion from ever truncating.
func coinOf(denom string, amount uint256) (chain.Coin, error) {
	if amount > math.MaxInt64 {
		return chain.Coin{}, ufmt.Errorf("%s %s is above the chain's coin maximum", strconv.FormatUint256(amount, 10), denom)
	}
	return chain.NewCoin(denom, int64(amount)), nil
}

// escrowForClient returns the per-client denom->amount tree, creating it on
// first access. Escrow is accounted per (client, denom) so a malicious client
// cannot release funds escrowed under a different client (see shared-escrow
// drain).
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

// addEscrowForClient records amount of denom escrowed under clientID. Used
// when this chain sends tokens over clientID (OnSendPacket); the matching
// release can only come back through the same client.
func addEscrowForClient(clientID, denom string, amount uint256) {
	t := escrowForClient(clientID)
	if x := t.Get(denom); x != nil {
		s, ok := overflow.Addu256(x.(uint256), amount)
		if !ok {
			panic("transfer: the escrow accounting would overflow")
		}
		amount = s
	}
	t.Set(denom, amount)
}

// checkEscrowForClient verifies clientID locked enough of denom, without
// mutating the accounting. Read-only so callers can move tokens between the
// check and the debit (see unescrowGRC20/unescrowNative).
func checkEscrowForClient(clientID, denom string, amount uint256) error {
	var have uint256
	if t := getEscrowForClient(clientID); t != nil {
		if x := t.Get(denom); x != nil {
			have = x.(uint256)
		}
	}
	if have < amount {
		return ufmt.Errorf("insufficient escrow for client %s denom %s: have %s, want %s", clientID, denom,
			strconv.FormatUint256(have, 10), strconv.FormatUint256(amount, 10))
	}
	return nil
}

// debitEscrowForClient subtracts amount from clientID's balance of denom.
// Assumes checkEscrowForClient already passed.
func debitEscrowForClient(clientID, denom string, amount uint256) {
	t := escrowForClient(clientID)
	have := t.Get(denom).(uint256)
	t.Set(denom, have-amount)
}

// unescrowGRC20 returns escrowed GRC20 tokens to receiver. The check runs
// before the transfer (per-client drain defense), the debit only after a
// successful transfer: OnRecvPacket returning Failure does not roll back realm
// store writes (IBCApp contract), so debiting first would lock the funds on a
// transfer failure.
func unescrowGRC20(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error {
	denomKey := ResolveGRC20Alias(denom)
	token := grc20reg.Get(denomKey)
	if token == nil {
		return ufmt.Errorf("GRC20 token %s not found in grc20reg", denomKey)
	}
	if err := checkEscrowForClient(clientID, denom, amount); err != nil {
		return err
	}
	teller := token.RealmTeller(0, rlm)
	if err := teller.Transfer(0, rlm, address(receiver), amount); err != nil {
		return ufmt.Errorf("unescrow GRC20 %s error: %v", denomKey, err)
	}
	debitEscrowForClient(clientID, denom, amount)
	return nil
}

// unescrowNative returns escrowed native coins to receiver. Same
// check-before-mutate ordering as unescrowGRC20: banker.SendCoins has no error
// return, but keeping the debit after the send avoids a lost-debit if that ever
// changes. Per-client isolation is enforced by checkEscrowForClient's
// accounting, not the banker, since the realm holds a single physical escrow
// account (no per-client addresses in Gno).
func unescrowNative(_ int, rlm realm, clientID, receiver, denom string, amount uint256) error {
	if err := checkEscrowForClient(clientID, denom, amount); err != nil {
		return err
	}
	coin, err := coinOf(denom, amount)
	if err != nil {
		return err
	}
	var (
		// TODO no app/clientID specific escrow address ?
		from   = rlm.Address()
		to     = address(receiver)
		banker = banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	)
	banker.SendCoins(from, to, chain.NewCoins(coin))
	debitEscrowForClient(clientID, denom, amount)
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

// VoucherSymbol returns the grc20 token symbol of the voucher of an IBC
// denom, "" if it has none yet. A voucher's symbol is allocated from a
// monotonic counter when the voucher is created ("IBC-" and the voucher's id
// in base 36, upper case: IBC-1, IBC-2, ..., within grc20's MaxSymbolLen),
// so no two vouchers ever share one, whatever their hashes; the full IBC
// hash stays the voucher's identity (its denom, and the grc20reg slug).
// grc20reg keys tokens by rlmpath.symbol, so callers locate a voucher via
// grc20reg.Get(<this realm's pkgpath> + "." + VoucherSymbol(ibcDenom)).
func VoucherSymbol(ibcDenom string) string {
	v := voucherTokens.Get(ibcDenom)
	if v == nil {
		return ""
	}
	return v.(*voucher).symbol
}

// voucherSymbolOf is the symbol of the voucher with grc20 id id.
func voucherSymbolOf(id uint64) string {
	sym := "IBC-" + strings.ToUpper(strconv.FormatUint(id, 36))
	if len(sym) > grc20.MaxSymbolLen {
		panic("transfer: voucher symbols are exhausted")
	}
	return sym
}

// getOrCreateVoucher returns the existing voucher instance for the given IBC
// denom, or creates a new one and registers it in grc20reg for DeFi
// discoverability. Non-crossing helper; rlm is needed to issue the cross
// call into grc20reg.Register from this realm's frame.
//
// The token's name is the base denom, its symbol is allocated from the
// voucher ids (see VoucherSymbol), and its grc20reg slug is the full hash:
// the registry key rlmpath.symbol is unique per voucher, so no denom,
// whatever its hash, can take another's key.
func getOrCreateVoucher(_ int, rlm realm, baseDenom, voucherDenom string) *voucher {
	if v := voucherTokens.Get(voucherDenom); v != nil {
		return v.(*voucher)
	}
	id := nextVoucherID.Next()
	sym := voucherSymbolOf(uint64(id))
	token, ledger := grc20.NewToken(baseDenom, sym, 0, id, rlm)
	inst := &voucher{token: token, ledger: ledger, symbol: sym}
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
func VoucherBalanceOf(ibcDenom string, addr address) uint256 {
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
