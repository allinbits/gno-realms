# IBC Transfer App

ICS-20 Fungible Token Transfer implementation for IBC v2 on Gno. Enables
cross-chain token transfers between Gno and any IBC v2 compatible chain.

## Transfer

`Transfer` is the single entry point for sending any token to another chain. The
token type is detected automatically from the `denom` argument:

| Token type  | Denom format | Example                   | Mechanism                                                |
| ----------- | ------------ | ------------------------- | -------------------------------------------------------- |
| Native coin | plain string | `ugnot`                   | Escrowed from the coins sent with the call               |
| IBC voucher | `ibc/{hash}` | `ibc/CAEF9C...`           | Burned from sender                                       |
| GRC20 token | grc20reg key | `gno.land/r/demo/foo.FOO` | Escrowed via `TransferFrom`                              |

Signature:

```gno
func Transfer(
    cur realm,
    clientID string,           // IBC client on this chain (e.g. "07-tendermint-1")
    receiver string,           // recipient address on destination chain
    denom string,              // token denomination (see table above)
    amount int64,              // amount to transfer
    timeoutTimestamp uint64,   // unix seconds after which the packet times out
    memo string,               // arbitrary memo included in the IBC packet
) (packet types.MsgSendPacket, sequence uint64)
```

Whatever the token, `Transfer` accepts only a direct user call (`gnokey maketx
call`): it checks `cur.Previous().IsUserCall()` before classifying the token,
so calls from intermediate code realms and from `maketx run` ephemeral realms
are rejected, for vouchers and GRC20 tokens as well as native coins. The
packet's sender is the transaction's origin caller.

`timeoutTimestamp` is in Unix seconds and the core enforces its bounds: it
must be after the current block time and at most 24 hours after it
(`now < timeout <= now + 24h`), and it must be greater than the latest
consensus timestamp the client holds for the counterparty. A literal
timestamp in a script goes stale; compute it at submission, e.g.
`$(( $(date +%s) + 3600 ))` for one hour from now, as the examples below do.

### Native coin

The coin must be attached to the transaction via the `-send` flag and must match
`denom` and `amount` (on an Ethereum route, the amount plus the route fee; see
the route controls section). `Transfer` reads the attached coins with
`unsafe.OriginSend()` (`chain/runtime/unsafe`), which is meaningful only
because of the direct-user-call check above: it ensures the coins actually
landed at this realm.

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
    -send 100ugnot \
    -args "07-tendermint-1" -args "atone1abc..." -args "ugnot" -args "100" \
    -args "$(( $(date +%s) + 3600 ))" -args "" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

### IBC voucher

IBC vouchers are GRC20 tokens minted when receiving tokens from another chain.
They are burned on transfer back to the source chain.

`Transfer` accepts the local `ibc/{HASH}` spelling and resolves it to the trace
itself. The counterparty direction is not symmetric: a hand-built ICS-20 payload
(raw `MsgSendPacket`) has no such resolution step and must carry the expanded
trace — see the header of `scripts/transfer-atomone-to-gno.sh`.

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
    -args "07-tendermint-1" -args "atone1abc..." \
    -args "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8" \
    -args "100" -args "$(( $(date +%s) + 3600 ))" -args "memo" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

### GRC20 token

The caller must first approve the transfer app realm to spend the tokens,
and attach no native coins to the `Transfer` call. On an Ethereum route the
route fee is drawn from the same allowance, separately and first, so the
allowance and the balance must cover `amount + fee` (the denom's current
`fee`, shown at `routes/{route}`); on other clients `amount` is enough.

From Gno code (e.g. in a `MsgRun` script):

```gno
transferAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
mytoken.Approve(cross(cur), caller, transferAddr, amount)
```

Or via `gnokey` directly, where `g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00` is
the transfer app realm address:

```
gnokey maketx call -pkgpath gno.land/r/demo/foo -func Approve \
    -args "g1caller..." -args "g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00" -args "100" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

Then call Transfer with the grc20reg key as denom:

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
    -args "07-tendermint-1" -args "atone1abc..." \
    -args "gno.land/r/demo/foo.FOO" -args "100" \
    -args "$(( $(date +%s) + 3600 ))" -args "" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

> [!IMPORTANT]
> GRC20 denoms are encoded into slash-free aliases for IBC packets by replacing
> `/` with `:` (e.g. `gno.land/r/demo/foo.FOO` becomes
> `gno.land:r:demo:foo.FOO`). The counterparty chain sees the aliased form, not
> the original grc20reg key.

## Authority

Administration follows the core realm's split (ADR pr6375 R14). The
tightening operation `BlockAddress` acts at once and is gated by an authority
(`p/aib/authority`) whose members are fixed at init to the GovDAO proxy and the
governance realm `gno.land/r/aib/ibc/ibcgov` (`IBCGovPath`); there is no
deployer member. GovDAO submits it with `NewBlockAddressProposalRequest`, as
described in the core README. Every other operation (`UnblockAddress`,
`UpdateImpl`, `AddAuthorityMember`, `RemoveAuthorityMember`, and the Ethereum
route controls of `GovApply`) is a decision of `gno.land/r/aib/ibc/ibcgov`
alone, with that decision's own delay: `UnblockAddress`, `UpdateImpl` and
`AddAuthorityMember` wait 7 days, while `RemoveAuthorityMember` (a
tightening) applies at once, as does ibcgov's own block decision; the route
controls' delays are listed in ADR 0004. Pausing is not the app's job: the core suspends any
application with `core.PauseApp("transfer")` (sends refused, incoming packets
answered with an error acknowledgement so the counterparty refunds, refunds
still delivered), and the home page shows a banner while that is the case; the
incident tool of the Ethereum route is its per-client flags (see the Ethereum
route controls section). The authority of this realm keeps a blocklist of
addresses, the equivalent of ibc-go's blocked addresses:

- `BlockAddress(addr)`: a blocked address can no longer send (`OnSendPacket`
  rejects it, so `Transfer` fails) nor receive (`OnRecvPacket` answers with an
  error acknowledgement, so the counterparty refunds its sender). Refunds to a
  blocked sender still go through: blocking never confiscates funds already in
  flight.
- `UnblockAddress(addr)`: removes it (an ibcgov decision, after 7 days).
- `IsBlocked(addr)`: reports the state; the `admin` page lists the blocklist.

The blocklist holds canonical (lowercase) addresses: bech32 also accepts the
all-uppercase spelling of an address, so `BlockAddress` and `UnblockAddress`
normalize their argument (and reject an invalid address), and `IsBlocked`
matches either spelling. On receive, `OnRecvPacket` decodes the packet's
receiver as ibc-go does, and every check and transfer uses the canonical form
(`CanonicalAddress`). On a non-Ethereum client, a receiver that is not a
valid gno address gets an error acknowledgement. On an Ethereum route it does
not: the transfer is booked as an owed sweep entry that keeps the raw
receiver, with a success acknowledgement, and only a governed sweep decision
naming a payee pays it (see the route controls section).

All of these are `MsgCall`-compatible and emit `block` / `unblock` /
`authority_member_added` / `authority_member_removed` events.

## Ethereum route controls

With `impl/v1` active (on a fresh deployment it is the transfer app's first
registered implementation, so it bootstraps with no decision; `impl/v0`
registers nothing), every Ethereum client is under the controls of ADR pr6375 §7; every other client keeps `impl/v0`'s
behaviour. The state lives in this realm (`InitExt("controls")`, the
`gno.land/p/aib/ibc/ics20/controls/v0` registry); the flags and holds live in
`gno.land/r/aib/ibc/ibcgov`, which also decides every change. Design and rule
mapping: [ADR 0004](../../../../../../docs/adrs/0004-ethereum-route-controls.md).

- **Routes.** An Ethereum client carries transfers only as the current client
  of a route ibcgov enrolled, and only in the denoms enabled on it (gno-native:
  `unescrow`; Ethereum tokens: `mint`, keyed by their voucher's `ibc/` denom).
  Escrow, vouchers and controls are keyed by the route key (the first client
  id); the denoms on the wire carry the current client id, so a route
  replacement re-points the route in constant work.
- **Sends** of a gno-native token: per-message minimum and maximum, the route
  fee charged on top (`-send` the amount plus the fee; the fee goes to the
  route's fee collector), receivers that are valid Ethereum addresses, not
  zero, not reserved, not a refused bridge contract and not the denom's own
  Ethereum token; a `sends` flag stops them. A voucher going back is never
  limited by the send minimum and maximum, charged a fee or stopped by a
  `sends` flag (or by a loss without a restoring decision), but waits until
  its denom is enabled on the route, is refused on a closed route, and its
  receiver passes the same recipient checks: a valid Ethereum address, not
  zero, not reserved, not a refused bridge contract and not the token itself
  (the voucher's base denom). Every send writes an immutable send record (full packet, commitment,
  sender, amounts, height) in the same transaction; a minted denom keeps the
  returned vouchers counted against its supply cap until the send settles.
- **Deployment.** The transfer app is deployed fresh with impl/v1 as its
  initial implementation; an Ethereum client carries nothing until ibcgov
  enrolls it as a route (there is no migration from impl/v0).
- **Receives** are refused with an error acknowledgement, before any state
  change, under a `credits` flag, on a closed route, for a denom not enabled,
  past a minted denom's supply cap, or for a blocked receiver. Otherwise they
  are booked as a claim keyed by the packet (or a sweep entry: below the fee,
  above the free lock, to a bridge realm, or to a receiver that is no gno.land
  address, kept raw), with a success acknowledgement.
- **`Claim(clientID, denom, n)`** (anyone; a positive `n` above 20 is taken
  as 20) pays up to `n` claims round-robin, looking at no more than `4n`
  recipients, and returns how many it paid (claims it moved to the owed
  sweep, their recipient having become a bridge realm, are not counted). A
  zero return does not mean every remaining claim is unpayable: the
  recipients it looked at may have had empty meters while others wait. It
  pays the oldest claim first per recipient, within the bridge meter (day cap
  `max(capFloor, lock/10)`, or the mint cap) and the recipient's meter (a
  quarter of it), the fee as the first installment (`min(remainder, the
  claim's fee, the denom's fee now)`: a claim reduced below its fee can
  finish as a fee payment alone), no slivers (a later
  installment needs at least `min(remainder, fee)` in both meters). A claim's
  fee is locked when it is credited (`fee` in the claims JSON), and the fee
  it pays is the lower of its fee and the denom's fee now, written back at
  each payout turn: the fee locked at credit is a ceiling a later raise
  never passes, and a cut applies and, once a payout turn has seen it, is
  kept.
  Meters start empty and restart empty when a `payouts` flag is cleared;
  nothing is paid under one.
- **Refunds** (error acknowledgement, timeout) are paid at once only when the
  whole refund fits: no `refunds` hold and the route not closed, no older
  refund of the denom waiting, the refund meter (`RefundCap` a day) holding
  the whole amount, and, for an `unescrow` denom, the escrow holding it.
  Otherwise the refund is queued. Queued refunds are paid first in, first
  out by **`ClaimRefunds(clientID, denom, n)`** (anyone; a positive `n`
  above 20 is taken as 20; nothing
  under a `refunds` hold or on a closed route), in installments: each takes
  what the meter (and, for `unescrow`, the escrow) allows of the head
  refund's remainder, at least `min(remainder, max(1, RefundCap/24))`, and
  the call stops at a head it cannot pay that much of. The outcome, the
  local processing height and the payment state are attached to the send
  record. Queued refunds are reserved: no receive or claim payout takes
  their escrow.
- **Closed routes.** A route replacement closes the route: no send, credit,
  claim payout or refund payout. It reopens by a governed decision, refused
  while a send record of a retired client is still open (its commitment
  outstanding or its refund queued, not settled by a reconciliation) or was
  processed (acknowledged or timed out) at or after the replacement's
  suspect height and is not settled; records completed and paid before the
  suspect interval need no settlement. The reopening records the remaining
  losses as an accepted deficit and revokes unpaid recapitalization
  authorizations, in batches of at most 64 incidents, then at most 64
  authorizations (`ReopenBatch`), continued by anyone with
  **`ContinueReopen(route)`**. A loss of any denom without a
  restoring decision stops new exposure only (gno-native sends, credits,
  claim payouts, sweep payments): voucher returns, acknowledgements, timeouts
  and refunds go on.
- **Governance** (`GovApply`, ibcgov only): enrolment, denom limits, fee
  collector, refused recipients, voids and restores of withheld claims, credit
  by vote, sweep payments (live entries of one denom, each paid whole to the
  decision's payee, with no claim fee and outside the payout meters; for an
  `unescrow` denom their total must fit the free escrow, what open and withheld claims and
  queued refunds do not reserve; deferred under a `payouts` flag), losses,
  recapitalization authorizations (only for
  an `unescrow` denom, the only kind recapitalized on gno.land; paid by
  anyone with **`Recapitalize(route, id)`**: for a native coin, a direct
  user call sending exactly the authorized amount; for a GRC20, no coins
  attached, the amount taken from the immediate caller's allowance to this
  realm), reductions, accepted deficits,
  settlements of a retired client's sends, route replacement and reopening.
- **Renders**: `routes`, `routes/{route}`, `routes/{route}/claims`,
  `routes/{route}/sweeps`, `routes/{route}/sends`, `routes/{route}/losses`
  (JSON pages of at most 100 entries, `{"entries":[...],"next":<cursor>}`:
  pass `next` as `?from=` for the following page, `""` when there is none;
  losses are
  ordered by direction then packet key), and the `route_*` events (`credit`,
  `claim`, `settle`, `refund`, `recapitalize`, `gov`).

## Query endpoints

All endpoints return JSON and are accessible via gnoweb or `gnokey query vm/qrender`.

| Path                                | Description                                                                        |
| ----------------------------------- | ---------------------------------------------------------------------------------- |
| `denoms`                            | List all registered IBC denominations                                              |
| `denoms/ibc/{hash}`                 | Details for a specific IBC denom (base, path, denom)                               |
| `total_escrow/{denom}`              | Total escrowed amount for a native denom                                           |
| `vouchers`                          | List all voucher tokens (paginated, includes `grc20reg_key`)                       |
| `voucher/ibc/{hash}`                | Voucher token metadata (denom, grc20reg_key, name, symbol, decimals, total supply) |
| `voucher/ibc/{hash}/balance/{addr}` | Voucher balance for an address                                                     |

Example:

```
gnokey query vm/qrender -data "gno.land/r/aib/ibc/apps/transfer:total_escrow/ugnot"
```

```json
{ "denom": "ugnot", "amount": 100 }
```

## Helper functions

### VoucherBalanceOf

Query the balance of a voucher token for a given address. Returns 0 if the
voucher does not exist.

```gno
balance := transfer.VoucherBalanceOf("ibc/CAEF9C...", addr)
```

### VoucherSend

Send an IBC voucher token to another Gno address:

```gno
transfer.VoucherSend(cross(cur), "ibc/CAEF9C...", recipient, 100)
```

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func VoucherSend \
    -args "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8" \
    -args "g1recipient..." -args "100" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

### VoucherApprove

Set a spender allowance for an IBC voucher token:

```gno
transfer.VoucherApprove(cross(cur), "ibc/CAEF9C...", spender, 100)
```

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func VoucherApprove \
    -args "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8" \
    -args "g1spender..." -args "100" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

### GRC20Alias

Convert a grc20reg key to the slash-free alias used in IBC packets.

```gno
alias := transfer.GRC20Alias("gno.land/r/demo/foo.FOO")
// "gno.land:r:demo:foo.FOO"
```

### NewDenom / NewHop

Construct a `Denom` (package `gno.land/p/aib/ibc/ics20/v0`, which holds the
ICS-20 types shared by the realm and its implementations) to compute the
expected IBC denom hash:

```gno
denom := ics20.NewDenom("uphoton", ics20.NewHop(transfer.PortID, "07-tendermint-1"))
ibcDenom := denom.IBCDenom()
// "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8"
```

## DEX integration for voucher tokens

Voucher tokens minted on `RecvPacket` are standard GRC20 tokens registered in
`grc20reg`. A DEX (e.g. Gnoswap) can discover and list them like any other
GRC20 token.

### Discovery

Voucher tokens can be discovered in two ways:

1. **From the transfer app** — query the `vouchers` render endpoint to list all
   voucher tokens with their metadata. Each entry includes a `grc20reg_key`
   field with the token's grc20reg key, ready for direct lookup. Supports
   pagination.

2. **From `grc20reg`** — `grc20reg` keys tokens by `rlmPath.symbol`, so voucher
   tokens are registered as `gno.land/r/aib/ibc/apps/transfer.{SYMBOL}`, where
   `{SYMBOL}` is the uppercase hex SHA256 hash from the `ibc/{HASH}` denom
   truncated to `grc20.MaxSymbolLen` (11 chars) — *not* the full hash, which
   exceeds the symbol length limit. Enumerate entries with the
   `gno.land/r/aib/ibc/apps/transfer.` prefix.

The token name is the base denomination (e.g. `uatom`) and the symbol is the
truncated hash (e.g. `CAEF9CA8CE6`). For the full denom and richer metadata
(trace hops, total supply), query the render endpoint `voucher/ibc/{HASH}`.

### Trading

1. A user receives voucher tokens via an IBC `RecvPacket`.
2. The user approves the DEX realm address to spend their voucher tokens
   (`Approve`).
3. The DEX interacts with the voucher via the standard GRC20 teller interface
   (`TransferFrom`, `BalanceOf`, etc.).

### Multiple vouchers for the same base denom

The same base denomination (e.g. `uatom`) arriving from different chains
produces distinct voucher tokens with different IBC hashes. A DEX should use the
full `ibc/{HASH}` denom to distinguish them — the token symbol is only the
truncated hash, so read the full denom from the `denom` field of the `vouchers`
render endpoint — and query `denoms/ibc/{HASH}` to resolve the trace path for
display purposes.

## Events

### `ibc_transfer`

Emitted in `OnSendPacket` for every outgoing transfer packet.

| Attribute  | Description                           |
| ---------- | ------------------------------------- |
| `sender`   | Sender address on source chain        |
| `receiver` | Receiver address on destination chain |
| `denom`    | Full denom path                       |
| `amount`   | Transfer amount                       |
| `memo`     | Memo text                             |

### `fungible_token_packet`

Emitted on `OnRecvPacket`:

| Attribute  | Description                |
| ---------- | -------------------------- |
| `sender`   | Sender address             |
| `receiver` | Receiver address           |
| `denom`    | Full denom path            |
| `amount`   | Amount                     |
| `memo`     | Memo text                  |
| `success`  | `"true"` or `"false"`      |
| `error`    | Error message (on failure) |

Also emitted on `OnAcknowledgementPacket`:

| Attribute         | Description                                                          |
| ----------------- | -------------------------------------------------------------------- |
| `sender`          | Sender address                                                       |
| `receiver`        | Receiver address                                                     |
| `denom`           | Full denom path (Ethereum route: the send record's accounting denom) |
| `amount`          | Amount                                                               |
| `memo`            | Memo text (not emitted on an Ethereum route)                         |
| `acknowledgement` | Acknowledgement bytes                                                |

followed by a second `fungible_token_packet` event carrying only `success`
(the acknowledgement's result) or `error` (its error).

### `denomination`

Emitted on every `OnRecvPacket` that credits a voucher (a token not
originating on gno.land), not only when its denom is first created; on an
Ethereum route, on every receive of a `mint` denom that passes the refusal
checks.

| Attribute    | Description                      |
| ------------ | -------------------------------- |
| `denom_hash` | Uppercase hex SHA256 hash        |
| `denom`      | JSON representation of the Denom |

### `timeout`

Emitted on `OnTimeoutPacket`.

| Attribute  | Description                                                                 |
| ---------- | --------------------------------------------------------------------------- |
| `receiver` | Refund recipient (original sender)                                          |
| `denom`    | Full denom path (Ethereum route: the send record's accounting denom)        |
| `amount`   | Non-Ethereum client: the refunded amount; Ethereum route: the whole send    |
| `memo`     | Non-Ethereum client: the original memo; Ethereum route: empty               |

On a non-Ethereum client the tokens are refunded in the same transaction. On
an Ethereum route the refund follows the refund rules of the route controls
section: `amount` is the send's whole entitlement even when the refund is
queued. What was actually paid is in the `route_settle` event (`refunded`,
the amount paid now, and `payment`, the record's payment state) and, for a
queued refund, in each later `route_refund` event of `ClaimRefunds`. The same
`route_settle` event follows an error acknowledgement.

## IBC packet lifecycle

1. **Transfer** -- Caller invokes `Transfer`. Tokens are escrowed (native/GRC20)
   or burned (voucher). An IBC packet is sent via `core.SendPacket`.

2. **RecvPacket** -- The destination chain receives the packet. On a
   non-Ethereum client, value moves at once: if the token originated on the
   destination chain, the escrowed tokens are returned; otherwise a voucher
   GRC20 token is minted and registered in `grc20reg`. On an Ethereum route,
   the receive only books a claim (or an owed sweep entry) with its success
   acknowledgement; the value moves later, when `Claim` pays the claim
   within the meters or a governed decision pays the sweep entry.

3. **Acknowledgement** -- On success, a non-Ethereum client emits two
   `fungible_token_packet` events (the acknowledgement's attributes, then
   `success`); on an Ethereum route the send record is first settled as
   delivered (its supply reservation released), emitting `route_settle`
   (`outcome`, `payment`, `refunded` 0), then the same two
   `fungible_token_packet` events. On failure, the sender is refunded (re-mint vouchers, unescrow
   native/GRC20): at once on a non-Ethereum client; on an Ethereum route,
   at once only when the whole refund fits, otherwise queued and paid by
   `ClaimRefunds` (see the route controls section).

4. **Timeout** -- If the packet is not received before `timeoutTimestamp`, the
   sender is refunded using the same mechanism as a failed acknowledgement.

On an Ethereum route the acknowledgement and timeout callbacks complete the
packet's transport (the core deletes its commitment) whether or not the
refund is paid in the same transaction; the send record tracks the payment.

## Escrow accounting

Native coins and non-IBC GRC20 tokens are escrowed at the transfer realm's
single account (Gno realms cannot own multiple addresses, so the ibc-go
per-channel escrow address approach is not available). Per-client isolation is
tracked in the realm store instead. For non-Ethereum clients:

- Escrow is tracked per `(client, denom)` in the realm store, not as a single
  global per-denom pool.
- `OnSendPacket` records escrow under the packet's `SourceClient` (the client on
  this chain that the token was sent over).
- `OnRecvPacket` debits the packet's `DestinationClient` (the client the
  returning token arrives on), which is the client that originally escrowed it.
  `checkEscrowForClient` rejects the release if that client never locked enough
  of the denom, so a packet arriving on a different client cannot drain escrow
  that belongs to another client. The matching `debitEscrowForClient` runs only
  after the token transfer succeeds, so a failed transfer leaves the accounting
  intact.
- A failed release returns an error acknowledgement; the escrow is untouched.

This prevents the shared-escrow drain: an attacker who creates their own client
and forges a valid proof against it cannot unescrow funds that honest users
locked under a different client. See
`z4f_on_recv_packet_drain_filetest.gno` for the regression test.

On an Ethereum route the escrow is keyed by the route's stable key (its first
client id), so it follows the route across client replacements. A send
escrows under it; a receive moves no value: it books a claim or a sweep
entry, and the escrow is released later, by `Claim` within the meters or by
a governed sweep payment. A receive above the free escrow (what open and withheld claims and
queued refunds do not reserve) is not refused: it becomes an owed sweep
entry, acknowledged with success.

## Upgrades

This realm is a permanent, thin proxy (see
[ADR 0002](../../../../../../docs/adrs/0002-proxy-realm-for-transfer-upgrades.md)):
it holds the escrow, the voucher tokens with their ledgers and the known
denominations, and forwards `Transfer`, the four IBC callbacks and `Render` to
an implementation realm that holds the ICS-20 logic. On a fresh deployment
the first, and so the bootstrapping, registration is
`gno.land/r/aib/ibc/apps/transfer/impl/v1`; `impl/v0` holds the ICS-20 logic
`impl/v1` embeds for non-Ethereum clients and registers nothing. The lifecycle is the core's
(`RegisterImpl(ctor, version, over, keepsControls)` from the implementation's
`init`, `UpdateImpl` by an ibcgov decision, `ImplPath` and `ImplVersion`); see
the core README's Upgrades section. Here the manifest also declares whether
the implementation keeps the route controls: once any route exists,
`CheckUpdateImpl` refuses an implementation that does not. The ICS-20 types
shared by every implementation live in `gno.land/p/aib/ibc/ics20/v0`.
