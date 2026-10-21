# ADR 0005: uint256 amounts on the Ethereum route

- Status: Proposed
- Date: 2026-10-21
- Implements: the gno.land side of gno ADR
  [`pr6375_ibc_ethereum`](https://github.com/clockworkgr/gno/blob/feat/secp256k1-validators-ibc/gno.land/adr/pr6375_ibc_ethereum.md)
  R15 and E10 as amended (256-bit amounts instead of a 6-decimal wrapper),
  and the amended §7.1, §7.9, §7.12, §7.13 and §8.4.
- Depends on: gno ADR `pr6387_native_int256` (the native `int256`/`uint256`
  types, `strconv.ParseUint256`/`FormatUint256`, `math/overflow`'s 256-bit
  helpers), gno ADR `pr6388_grc20_uint256` (`p/nt/grc20/v1`,
  `r/nt/grc20reg/v1`), ADR 0002, ADR 0004.
- Supersedes: ADR 0004's "Checked arithmetic" section and every rule of it
  that cut, parked or refused a payout for the int64 range (the minted
  supply's "headroom", the wide counters, the int64 liability bound).

## Context

Every amount of the transfer app and its route controls was an `int64`:
the ICS20 amount was parsed with `strconv.ParseInt`, vouchers were
`p/nt/grc20/v0` tokens, and the escrow accounting held `chain.Coin`s. An
ICS20 amount on the wire is a decimal of up to 2^256 - 1, Ethereum's
transfer app carries up to 2^96 - 1 (gno ADR pr6375 E6, §7.2), and an
18-decimal ERC20 passes 2^63 - 1 at about 9.22 tokens, so the route could
carry only dust of such a token (pr6375 R15), and the controls needed three
workarounds for aggregates that could genuinely pass 2^63: exact "wide"
two-limb counters with saturating views for the reservation and loss
totals, a minted denom's "headroom" (`MaxInt64 - Outstanding`) that cut
claim and refund installments and parked a settlement's refund the supply
could not hold, and a refusal of any receive that would take the
liabilities past int64 (ADR 0004, "Checked arithmetic").

The VM now has native `uint256` (gno ADR pr6387), whose arithmetic wraps
like Go's with checked helpers in `math/overflow`, and a GRC20 standard
counting in it (`p/nt/grc20/v1`, gno ADR pr6388). Chain coins stay `int64`
(an owner decision of pr6388). The deployment is fresh: no state to migrate.

## Decision

### Amounts are uint256; coins stay int64

| Value | Type | Where it meets an int64 |
|---|---|---|
| ICS20 packet amount (`ics20.Token.Amount`, a decimal string on the wire) | parsed with `Token.AmountUint256`: `strconv.ParseUint256(s, 10)`, digits only (no sign, space or separator; leading zeros as `ParseUint` reads them), `0` refused by `ValidateBasic`/`ValidateBasicEthereum` | `Token.ToCoin` refuses an amount above `math.MaxInt64` |
| vouchers (minted for Ethereum tokens, and for Tendermint routes alike) | `p/nt/grc20/v1`, registered in `r/nt/grc20reg/v1`; `MintVoucher`, `BurnVoucher`, `VoucherSend`, `VoucherApprove`, `VoucherBalanceOf` take and return `uint256` | never |
| GRC20 escrow of a gno-native token | a `grc20reg/v1` token, moved by its v1 teller | never |
| the escrow accounting (`Store.AddEscrow`, `CheckEscrow`, `Escrowed`, `IterateEscrow`), per (client, denom) | `uint256` | a native coin landing here widens (`transfer.CoinAmount`, which refuses a negative amount); a native release converts with a range check (`coinOf`: above `math.MaxInt64` is refused, which the escrow invariant never reaches, since the escrow is made of coins) |
| `transfer.Transfer`'s `amount`, `Logic.Transfer` | `uint256` | a native send's amount, plus the route fee on an Ethereum route, must fit an int64 or no coin sent can match it: refused with "above the chain's coin maximum" |
| every controls amount (`DenomConfig`, `Claim`, `SweepEntry`, `SendRecord`, `Totals`, `IncidentTotals`, `Loss`, `Recap`, `Payment`, `RefundPayment`, `SettleItem`, `Meter.Level`) | `uint256` | never |
| the governance builders' amount parameters (`NewSetDenomRequest`, `NewCreditRequest`, `NewRecordLossRequest`, `NewRecapitalizeRequest`, `NewReduceRequest`, `NewAcceptDeficitRequest`, `NewEthLimitsRequest`; `NewSettleRequest` and `NewEthSettleRequest` parse their item amounts with `ParseUint256`) | `uint256`; `maketx call` takes the same canonical decimal strings as before, and now values past 2^63 | never |
| `controls.Params` on the wire (`codec.gno`) | `Amount` and the `DenomConfig` fields as 32 big-endian bytes (`wire.Writer.Uint256`); a new `ID int64` carries the authorization id of `OpRevokeRecap`, which used to ride in `Amount` | never |
| heights, times, sequences, ids, counts | `int64`/`uint64`, unchanged | — |

`ufmt` and `uassert` take no `uint256` (pr6388), so every message and render
formats amounts with `strconv.FormatUint256`, and the unit tests compare them
natively.

### The Ethereum bound: 2^96 - 1

Ethereum's transfer app refuses a send or a receive above `2^96 - 1`
(`ICS20InvalidAmount`; pr6375 E6, §7.2, §9). `abi.MaxAmount` names it on
this side, and the transfer app applies it on an Ethereum route before any
state change: a send above it is refused by `Transfer` (it would only come
back refused and refunded), and a receive above it, which no genuine
Ethereum send carries, is answered with the universal error acknowledgement.
Every amount on a route is therefore at most `2^96 - 1`, which bounds every
aggregate far below `2^256` (it would take `2^160` packets to pass it).
Tendermint routes keep the full `uint256` range, as ibc-go does.

### Arithmetic of the controls (replaces ADR 0004's section)

Every aggregate goes through `controls/arith.gno`, by what reads it:

| Helper | Rule | Used by |
|---|---|---|
| `checkedAdd` | refuses the operation that would pass `2^256 - 1` before anything changes | a credit's liabilities (`CheckCredit`, `CreditPending`: the "would overflow what is owed" refusal keeps its rule, at the uint256 maximum), every loss against the denom's and the incident's outstanding balances (`lossFits`: one recorded by decision, `RecordLoss`; `lossesFit`: a forged void's payouts and a settlement's forged refunds and receives, each batch summed per denom), a sweep payment's total and the outstanding supply it adds to (`PaySweeps`), a settlement's escrowed refunds total (past the maximum the denom's refunds all park), `payable`'s per-denom totals and a voucher token's supply |
| `mustAdd`, `mustSub` | an overflow or a negative result where an earlier check bounds the result is a broken invariant and aborts the transaction | every move between totals, every payment within what is owed, the reservation and loss counters (`InFlight`, `Returning`, `QueuedRefunds`, `ProvenOwed`, `OpenUnrecovered`, `OpenUnresolved`), the escrow accounting (`addEscrowForClient`) |
| `boundAdd` | saturates at the maximum: a sum used only as the upper bound of what is reserved or booked can only refuse more | `Reserved`, `booked`, `liabilities`, `Route.Unrecovered`/`Unresolved` |
| `statAdd` | saturates: a statistic no check reads | `Credited`, `Paid`, `Fees`, `SweepPaid`, `Sent`, `SendFees`, `Refunded`, `Lost`, `Recapitalized`, `Reduced`, `Accepted`, a reopening's accepted total |
| `sub0` | floors at zero | the free lock (`lock - Reserved()`), the supply before the controls (`Outstanding` at a return), the room under a supply cap, a meter's `Take` |

`Meter` levels, rates and ceilings are `uint256`; a refill whose whole-days
part overflows fills the meter (the ceiling bounds it anyway), and the
fractional part stays below `2·Day²`. The wide counters (`wide`, two limbs)
and their saturating views are gone: every total is exact and the JSON shows
it whole.

### Rules that change, each only because the int64 range was its reason

1. **No minted headroom.** A minted denom's payouts were cut to
   `MaxInt64 - Outstanding` (a claim installment, a queued refund
   installment, an immediate refund queued when it would not fit) and a
   settlement's refund the supply could not hold was parked, owed and
   reserved in its own total (`Parked`), paid as returns freed capacity.
   Nothing bounds the vouchers a refund mints again now (the supply cap
   governs admission only, as before), so: a claim installment is bounded
   by the meters alone; a queued refund installment by the refund meter
   alone; an immediate refund is paid at once within the refund meter
   whatever the supply; a sweep payment is refused only past `2^256 - 1`;
   and **a minted settlement refund is always paid at once**, never parked
   (`PlanSettlement` takes no "room" function any more; `park` holds only
   escrowed refunds whose free escrow is short, exactly as before). The
   `Parked` total, the `parked` JSON field and the minted branches of
   `park`/`refunded` are removed. The escrowed rules are unchanged: an
   escrowed settlement refund parks when the free escrow once the batch
   applies is short, the batch paid all together or not at all.
2. **The receive refusal "would overflow what is owed"** keeps its rule
   with its bound moved from `2^63 - 1` to `2^256 - 1` (unreachable on a
   route, since each packet is at most `2^96 - 1`); a receive above
   `2^96 - 1` is refused instead (above).
3. **A loss the ledger could not hold is refused**, before anything
   changes, where the wide counters took any loss: one recorded by decision
   (`NewRecordLossRequest`, spent), and the losses a forged void or a
   settlement derives from paid claims, entries and refunds, checked whole
   (summed per denom, against the denom's and the incident's outstanding
   balances with every earlier loss) so a batch never aborts halfway; the
   void or settlement is refused and the decision spent. Each loss is
   within a booked payout, but the balances are not bounded by it. (A
   balance near `2^256` takes a recorded loss of that size: unreachable on
   a route by traffic, but a decision can record one.)
4. **Native coin boundary**: a native send whose amount plus the route fee
   is above `math.MaxInt64` is refused (before, "the amount plus the route
   fee overflows"); a native release above it is refused by the store; and
   **a recapitalization in coins is at most `math.MaxInt64`**, refused by
   `NewRecapitalizeRequest` and by `GovApply` (it is paid as one coin, an
   int64, so a larger authorization could never be paid and would reserve
   the incident's losses until revoked); a GRC20 one keeps the `uint256`
   range.
5. **Renders and events**: every amount in the controls' JSON
   (`routes/<route>`, `claims`, `sweeps`, `sends`, `losses`), in the
   transfer realm's `total_escrow/<denom>`, `vouchers`, `voucher/ibc/<hash>`
   and `.../balance/<addr>` documents, and in events is a **decimal
   string**, since a 256-bit value does not survive a reader that parses
   JSON numbers as doubles (the TypeScript relayer reads these renders);
   heights, times and counts stay numbers.

Everything else the controls decide — meters and caps, claims and sweeps,
voids and restores, the loss ledger's remedies, send records, the refund
meter and hold, preparation, proofs and settlements, reopening, route
replacement — keeps its rules and its tests, ported to `uint256`.

### What the implementations do

- `apps/transfer` (the proxy): the `Store` interface takes `uint256` amounts
  and a denom string where it took a `chain.Coin` (`AddEscrow`,
  `CheckEscrow`, `EscrowGRC20`, `UnescrowGRC20`, `UnescrowNative`,
  `MintVoucher`, `BurnVoucher`, the pending sends); the escrow tree holds
  `uint256` per (client, denom); vouchers are `grc20/v1` tokens registered
  in `grc20reg/v1`. The proxy is not deployed yet (ADR 0002, 0004), so its
  surface may still change.
- `impl/v0` (Tendermint routes): the same logic over `uint256`, converting
  to a coin only on the native paths.
- `impl/v1` (Ethereum routes): the bound above on `Transfer` and
  `OnRecvPacket`; `payable` checks a voucher's supply against `2^256 - 1`
  and a native payment against `math.MaxInt64`; `GovApply` reads
  `Params.ID` for a revocation and refuses a recapitalization in coins
  above `math.MaxInt64`.
- `ibcgov`: the builders take `uint256` amounts; kind 4 encodes them with
  `abi.Uint256Of` (the wire bytes are unchanged, pinned by the vector
  filetests z2b and z2c); kind 12 parses its item amounts strictly;
  `NewRecapitalizeRequest` refuses an amount in coins above
  `math.MaxInt64`.
- `e2e`: the allowance test's spender script imports `grc20reg/v1` and
  spends a `uint256`.

### Tests

- `controls`: the unit tests are ported; those that pinned saturation or
  the headroom now pin exact totals past int64 or the absence of any cut:
  `TestAggregatesNeverWrap` (exact totals, the liability refusal at the
  maximum, saturating reservations and statistics, a minted refund past
  int64), `TestMintedPayoutsUnbounded` (replaces `TestMintedPayoutHeadroom`),
  `TestMintedSettlementRefundsNeverPark` (replaces
  `TestParkedSettlementRefund`, `TestParkedRefundLetsReturnsBurn` and
  `TestMintedRefundsBeyondInt64`), `TestSettlementReleasesBeforePaying`,
  `TestSettlementNetReservations` (both refunds paid),
  `TestLossesNearMaximum`, `TestBatchLossesNeverWrap`,
  `TestLossCapacityFreedByRecovery` (a loss past the maximum refused),
  `TestForgedVoidLossesPreflighted` and `TestSettlementLossesPreflighted`
  (derived losses refused whole, per denom, against the balances every
  incident shares),
  `TestLossLedgerBeyondInt64`, `TestMeterNearMaxCap` (the largest cap),
  `TestReturnAfterPartialRefund` (9e19 vouchers). The int64 escrow
  boundary of `TestStaggeredProofsKeepSiblingBacking` stays, as the escrow
  of a native denom is still an int64.
- `ics20`: `Token.ToCoin` above the coin maximum; a signed amount is a
  syntax error.
- `transfer`: the escrow accounting past int64 (`TestEscrowAccumulatesPerClientDenom`), the
  coin boundary (`TestCoinOfBoundary`); filetest z9zf (a receive at
  `2^96 - 1` booked, one above it error-acked) and z9zw (a settlement pays
  a minted refund whole with the supply past int64) replace their int64
  versions; z9d refuses a recapitalization in coins above `math.MaxInt64`
  at the builder and at `GovApply`, a GRC20 one passing both; every golden
  with amounts shows them as strings.

## Alternatives considered

1. **A 6-decimal wrapper on Ethereum (pr6375 E10)**: keeps int64 on
   gno.land at the price of a second contract, dust refunds and a cap on
   every 18-decimal token; superseded by the native type.
2. **Keeping the wide counters and the headroom over `uint256`**: the
   bound they worked around is gone; keeping them would keep two
   representations of one number and a parking path nothing reaches.
3. **Bridging `grc20/v0` tokens as well** (a second registry lookup and a
   second token type in the store): left out; a v0 token is bridged through
   a v1 wrapper, which keeps one amount type end to end. Open question
   below.
4. **JSON numbers for amounts**: valid JSON, but lossy for every reader
   that parses numbers as doubles; strings are the convention gno ADR
   pr6387 recommends.
5. **Panicking at `2^256`** everywhere instead of the refusals above: a
   governed decision would then abort and stay pending instead of being
   spent (ADR 0004, "Governed execution spends rather than aborts").

## Consequences

- Breaking API changes, acceptable on a fresh deployment: `transfer.Transfer`,
  `VoucherSend`, `VoucherApprove` and `VoucherBalanceOf` take and return
  `uint256`; the `Store` and `Logic` interfaces, the controls package, the
  governance builders and `controls.Params`' wire format change as above.
- Readers of the renders and events (the monitors, the watch tool, the
  TypeScript relayer, the e2e suite) parse amounts as decimal strings.
- The route launches on a fresh chain (pr6375 §13, the owner's decision),
  never by an in-place upgrade: its genesis is built from a gno release
  carrying #6387 and #6388, lists `p/nt/grc20/v1`, `r/nt/grc20reg/v1` and
  `p/nt/treasury/v1` with the IBC realms (pr6388: a `p/nt` path cannot be
  added after genesis), and passes the #6387 rollout's reserved-name scan
  (no genesis package declares `int256` or `uint256`, or imports a package
  of either name unaliased). The test tooling fetches the v1 packages from
  the pinned gno's examples (`make mod-download`).
- The realms cannot be transpiled to Go (they use `uint256`), which nothing
  in this repository does.
- ADR 0004's "Checked arithmetic" table and its headroom rules are
  superseded by this document.

## Open questions

1. Whether to bridge `grc20/v0` tokens (a second registry lookup, two token
   types in the store), or leave them to a v1 wrapper.
2. Whether the Ethereum bound stays a constant of the transfer app
   (`abi.MaxAmount`) or becomes a per-route governance parameter, should
   Ethereum's transfer app ever raise it by a kind 7 upgrade.

## Review log

- Round 1 (code: 3 P2; design: 1 P2, 4 P3): a recapitalization in coins
  bounded by `math.MaxInt64` at the builder and at `GovApply` (rule 4); the
  losses a forged void or a settlement derives checked whole, per denom,
  against the ledger's balances before anything changes (rule 3,
  `lossesFit`, `TestForgedVoidLossesPreflighted`,
  `TestSettlementLossesPreflighted`); the e2e allowance test moved to
  `grc20reg/v1`; the runbook's settlement step no longer parks minted
  refunds; pr6375 §7.1, §7.12 and §8.5 19 corrected, and its launch
  rewritten around a fresh chain whose genesis carries #6387/#6388 (the
  owner's decision; Consequences).
