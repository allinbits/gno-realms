# ADR 0002: Proxy realm for upgradeable transfer app

- Status: Accepted
- Date: 2026-10-05
- Issue: [#22](https://github.com/allinbits/gno-realms/issues/22) (Use proxy realms)
- Plan: [`docs/upgradability-plan.md`](../upgradability-plan.md), §5.3
- Depends on: [ADR 0001](./0001-proxy-realm-for-core-upgrades.md)
- Deciders: @tbruyelle

## Context

`gno.land/r/aib/ibc/apps/transfer` has the same immutability problem as core,
and the things bound to its path are the ones holding user funds:

1. **Realm address.** Native coins are escrowed at the realm's address and
   released with a `RealmSend` banker from `rlm.Address()`; GRC20 escrow is a
   `TransferFrom` to `cur.Address()`, which users pre-approve for that exact
   address.
2. **Voucher tokens.** Each IBC denom received gets a `grc20` token created by
   the transfer realm and registered in `grc20reg` under
   `gno.land/r/aib/ibc/apps/transfer.<SYMBOL>`; `grc20reg.Register` requires the
   key to start with the caller's path. Holders' balances and DeFi integrations
   are keyed on it, and the `PrivateLedger` that mints and burns is a capability
   held by the realm that created the token.
3. **Core app registry.** The realm value registered under port `transfer` is
   what core calls back; core refuses a second registration for the port.
4. **Event `pkg_path`** for the transfer events (`transfer`, `packet`, `timeout`,
   `denom`), used by the render pages and tooling.

A new transfer realm at a new path would strand escrowed funds and approvals,
start with empty voucher ledgers, and could not take the port.

## Decision

Apply ADR 0001 to the transfer realm: `gno.land/r/aib/ibc/apps/transfer` is a
permanent proxy, the ICS-20 logic lives in `gno.land/r/aib/ibc/apps/transfer/impl/v0`
and is invoked non-crossing. The lifecycle (`RegisterImpl`, `UpdateImpl` with
`OnInstall`, bootstrap auto-activation, `NewUpdateImplProposalRequest`,
`ImplPath`/`ImplVersion`, Render disclosure) and the gating by `p/aib/authority`
are the same as in ADR 0001 and are not repeated here.

### Frozen surface

1. **User entry points** with their current signatures: `Transfer`,
   `VoucherSend`, `VoucherApprove`; the read helpers `VoucherBalanceOf`,
   `VoucherSymbol`, `GRC20Alias`; `Render`. Logic-bearing ones forward
   non-crossing to the implementation.
2. **The direct-user-call guards stay in the proxy.** `Transfer` keeps
   `cur.Previous().IsUserCall()` and the `OriginSend` check, and hands the
   verified coin to the callback through the proxy-owned pending slot
   (`pendingNativeEscrow`, cleared by `defer`), as today. The non-crossing
   forward preserves `cur.Previous()`, so the implementation sees the same facts.
3. **`App` implementing `app.IBCApp`**, registered once in `init` as today.
   Each callback keeps its core-caller assertion (PR #60) in the proxy and
   forwards non-crossing.
4. **Administration stays in the proxy**: authority membership, the blocklist
   (`BlockAddress`/`UnblockAddress`/`IsBlocked`), the proposal constructors.
   The blocked-address check runs in the proxy before delegating.
5. **Store owned by the proxy**: `denoms`, per-client escrow accounting
   (`totalEscrow`), `voucherTokens` (token plus `PrivateLedger`, never returned
   to callers), `nextVoucherID`, the three pending slots. Exposed through
   accessors gated on `rlm.IsCurrent() && rlm.PkgPath() == transferPkgPath`.
6. **Value-moving services in the proxy**, taking `rlm`: `banker.NewBanker(
   banker.BankerTypeRealmSend, rlm)` sends, grc20 `RealmTeller(0, rlm)`
   transfers, voucher mint and burn through the ledger, token creation and
   `grc20reg.Register(cross(rlm), ...)`. They work because the current realm is
   the proxy, the token's home realm; the ledger pointer is only ever used
   inside proxy code.
7. **Gated `Emit*` wrappers** for the four transfer event types.

### `Logic`

The four IBC callbacks plus the user-side logic of `Transfer`, in the
non-crossing form, with `Version()` and `OnInstall` as in ADR 0001:

```gno
type Logic interface {
    Version() string
    OnInstall(_ int, rlm realm, prevPath, prevVersion string)
    Transfer(_ int, rlm realm, sender address, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string)
    OnSendPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error
    OnRecvPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult
    OnTimeoutPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error
    OnAcknowledgementPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, acknowledgement []byte, payload types.Payload) error
}
```

The callbacks mirror `p/aib/ibc/app.IBCApp` in the non-crossing form. The
implementation holds the denom tracing, escrow and refund rules, and decides what
to mint, burn, escrow or release; the proxy performs the movement.

### What an implementation may and may not do

As in ADR 0001: it runs as the proxy, uses only the store accessors, the
value-moving services and the `Emit*` wrappers, exports nothing that mutates,
writes no params and emits nothing on its own path, keeps no state of its own,
and its `init` only registers.

## Consequences

Positive:

- Escrowed coins, GRC20 escrow, user approvals, voucher ledgers and the
  `grc20reg` keys survive an upgrade because the proxy's address and path never
  change and the ledgers never leave it. The port registration in core is the
  proxy forever, which is why core needs no `ReplaceApp` (issue #59).
- A transfer upgrade is an ordinary implementation upgrade: same runbook, same
  authority, no counterparty or relayer involvement.

Negative:

- **Frozen surface**, including the user entry points. Interface-typed
  parameters are not available here (the arguments are scalars for `MsgCall`),
  so a new user-facing operation after mainnet means a new entry realm. The
  pre-mainnet freeze review covers this list.
- **The active implementation is fully trusted** with escrow and voucher
  supply, gated by the same authority as core's.
- Two more realms to deploy and list in `scripts/packages.sh`, the gnodev paths
  and the e2e entrypoint, and one blank import per transfer filetest.

## Alternatives considered

- **No proxy, redeploy a new app at a new path and port.** Funds and approvals
  stranded in the old realm, new empty voucher tokens, no way to take the
  `transfer` port. Rejected.
- **Keep the ICS-20 logic in the proxy and only make core upgradeable.** The
  transfer rules (denom tracing, refund paths, blocklist behavior) are at least
  as likely to need fixes as the core lifecycle, and the proxy surface needed to
  make them swappable later cannot be added after deploy. Rejected.
- **Ledgers in the implementation realm.** A `PrivateLedger` created by an
  implementation would be that realm's capability and would be lost at the next
  switch; `grc20reg` keys would also carry the implementation path. Rejected,
  as onbloc did for the same reason.

## References

- ADR 0001 for the mechanism, the attribution facts and the versioning layout.
- onbloc `gno-ibc` `apps/ucs03_zkgm`: voucher ledgers kept in the app proxy "so
  their mint/burn rights survive impl upgrades" (`voucher.gno`).
- `docs/resources/gno-security-guide.md`: `CallerTeller` pinned to the token's
  home realm; `/p/` methods on foreign receivers as capabilities.
