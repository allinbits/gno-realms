# Contract upgradability plan

- Status: decided 2026-10-01 (§8), implementation not started
- Scope: `r/aib/ibc/core`, `r/aib/ibc/apps/transfer`, their `p/aib/...` dependencies,
  deploy scripts, tests
- Related: issue #22 (Use proxy realms), issue #36 (govDAO callback for admin-gated
  functions), branch `chore/proxy` (ADR 0001 "Proxy realm for upgradeable IBC core",
  WIP from July 2026, never merged, based on `135bd38`)

Master has no upgrade mechanism today. This document inventories what is
path-bound, states the Gno rules the design has to respect, compares the options,
and lays out a phased delivery. Section 8 records the decisions taken.

## 1. Why this has to be designed in before the first mainnet deploy

Gno has no in-place upgrade primitive:

- `MsgAddPackage` on an existing public path fails with `package already exists`
  (`gno.land/pkg/sdk/vm/keeper.go:801-805`). There is no upgrade, replace or
  migrate message (`vm/msgs.go` has `MsgAddPackage`, `MsgCall`, `MsgRun`,
  `MsgEnablePackage`, `MsgRejectPackage` only). The MANIFESTO lists "realm
  upgrading" and a path name registry as future work (`docs/MANIFESTO.md:1087-1097`).
- The one redeployable kind of realm is `private = true`
  (`docs/resources/configuring-gno-projects.md:55-63`). A private realm cannot be
  imported by anyone and none of its objects or types may be stored in another
  realm. Our core is imported by transfer, and a proxy has to hold a reference to
  its implementation, so private realms do not fit (see §4).

So "upgradable" means: a permanent realm whose code never changes, written so that
the parts we expect to change can be swapped by an authorized party later. Every
hook, gate and accessor the future needs must exist in that permanent realm on day
one. `r/gnops/valopers/admin.gno:144-158` says it plainly for its own rotation
entry point: "It must exist before deploy, because code cannot be added to a
deployed realm."

The project currently targets the onyx testnet (`scripts/env.sh`). The first
mainnet deploy is the point after which the frozen surface can no longer change.

## 2. What is path-bound today

| # | Identity | Where it is produced | Who depends on it | If the path changed |
|---|---|---|---|---|
| 1 | Chain-param namespace `vm:gno.land/r/aib/ibc/core:` for packet commitments, receipts, acks | `core/store.gno:73-84,98-111,168-177,186-190`; prefix added by gnovm `chain/params/params.go:99-108` from the *current realm* | AtomOne `10-gno` light client proves these keys; `cmd/gen-proof` vectors | Every counterparty proof fails; the counterparty must re-register |
| 2 | Event `pkg_path = gno.land/r/aib/ibc/core` | `chain.Emit` stamps the package whose code contains the call (`gnovm/stdlibs/chain/emit_event.go:67-68`) | ts-relayer via tx-indexer GraphQL, e2e | Relayer stops seeing events |
| 3 | Entry-point path and signatures (`CreateClient`, `UpdateClient`, `RegisterCounterparty`, `SendPacket`, `RecvPacket`, `Acknowledgement`, `Timeout`, `WriteAcknowledgement`, `UpgradeClient`, `RecoverClient`) | `core/core.gno`, `core/client.gno` | ts-relayer MsgRun templates hardcode the import (`atomone/ibc-v2-ts-relayer/src/clients/gno/templates/*.gno.ts`) | Relayer release needed |
| 4 | Transfer realm address | `unescrowNative` sends from `rlm.Address()` (`transfer/transfer.gno:469-483`); GRC20 escrow is `TransferFrom(..., cur.Address(), ...)` (`transfer/app.gno:140-142`); README tells users to approve `g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00` | Escrowed native coins, escrowed GRC20 balances, user approvals | Funds stranded in the old realm, approvals void |
| 5 | Voucher tokens | `grc20.NewToken` by the transfer realm, registered in grc20reg under `gno.land/r/aib/ibc/apps/transfer.<SYMBOL>` (`transfer/store.gno:141-150`); grc20reg `Register` requires the token id to start with the caller's path | Holders' balances, DeFi integrations keyed on the grc20reg key | New realm means new, empty tokens; old ledgers unreachable |
| 6 | Core app registry | `routes[portID]` stores the app value plus its `pkgPath` and `address`; `RegisterApp` rejects a second registration for a port (`core/app.gno:317-333`); `pendingAsyncAck.appPkgPath` and the `WriteAcknowledgement` caller gate (`core/core.gno:253-259`) | Any transfer successor | A new transfer realm cannot take port `transfer` |
| 7 | Light-client code | `tendermint.NewTMLightClient()` hardwired in `core/store.gno:204-209`; stored `*TMLightClient` objects are bound to the deployed `p/aib/ibc/lightclient/tendermint` | Every existing client | A verification bug fix needs a new core |
| 8 | Admin and relayer ACL | EOA compared with `unsafe.OriginCaller()` (`core/admin.gno:244-306`) | `RecoverClient`, relayer whitelist, `SetAdmin` | Issue #36 wants GovDAO here |
| 9 | UX and tooling paths | `transfer/render.gno:23` (`transferRealmPath` for txlinks), render links in both realms, `scripts/*.sh`, `e2e/query.go` | Adena users, scripts, CI | Breakage, but fixable off-chain |

Rows 1 to 6 are the ones that make "redeploy at a new path" unacceptable for both
realms. Rows 7 and 8 are what we want to be able to change.

## 3. Gno facts the design relies on

Verified against the pinned `gnolang/gno v1.5.0` (the attribution files are
byte-identical between `v1.5.0` and `../gno` HEAD `305d825b6`).

Attribution (two different mechanisms, do not conflate):

- `params.SetBytes` prefixes keys with the *current realm*, which is the realm
  of the most recent crossing frame (`execctx.CurrentRealm`,
  `gnovm/stdlibs/internal/execctx/realm.go`). A non-crossing call never changes
  it. Code from another package that runs non-crossing inside our frame writes
  params under *our* prefix.
- `chain.Emit` stamps the package that lexically contains the call. Only code
  physically inside the `core` package can emit `pkg_path=gno.land/r/aib/ibc/core`.

Storage and mutation (`docs/resources/gno-interrealm.md`):

- An object belongs to the realm that allocated it. A `/r/X`-declared method
  always runs with X's storage authority (borrow rule #1, `:60-90,489-534`), so an
  exported core-declared method on a core-owned object can mutate it no matter
  which realm calls it. A `/p/` method on a foreign receiver runs with the
  receiver's realm authority (borrow rule #2): holding a `*grc20.PrivateLedger`
  or `*bptree.BPTree` pointer is a capability
  (`docs/resources/gno-security-guide.md:188-198,206-221`).
- A realm cannot construct another realm's `/r/`-declared types (composite
  literal, `new`, `make`; `:337-346`). Types shared between versions must live in
  `/p/`, and a proxy must expose constructors for its own types.
- `realm` values cannot be forged (hidden `.seal` method) and `rlm.IsCurrent()`
  survives being threaded through non-crossing calls, so a gate of the form
  `rlm.IsCurrent() && rlm.PkgPath() == proxyPath` is sound (verified in the
  `chore/proxy` branch notes against the then-current pin, unchanged since).

Deploying on mainnet (`misc/deployments/mainnet.gno.land/README.md:17`,
`gen-genesis.sh:313-392`):

- `code_submission_policy = inert`: a post-genesis `MsgAddPackage` is stored, not
  executed, and becomes live only when the gpao approvals oracle sends
  `MsgEnablePackage` with the package hash. `init()` runs at enable time, not at
  submission (`vm/keeper_inert.go`).
- `MsgRun` may be allowlisted (`run_submitters`), as on lab1. Governance and
  upgrade entry points should therefore stay `MsgCall`-compatible (strings,
  addresses, integers only).
- Storage deposits are locked per realm and refunded only when realm code deletes
  data; there is no eviction message (`docs/resources/storage-deposit.md`,
  `vm/keeper.go:2334-2490`). An abandoned implementation realm should hold no
  state worth paying for.

Governance constraints (`docs/CONSTITUTION.md:1173-1197`, "Realm Upgrading"):
upgradeable realms must be shown as such in gnoweb; no types declared in an
upgradeable realm may be persisted in an immutable realm; immutable realms may not
import upgradeable ones; `/p/` libraries are never upgraded.

Reference implementations:

- `r/gov/dao`: unversioned proxy storing a `DAO` interface value;
  `UpdateImpl(cur, UpdateRequest)` gated by an `allowedDAOs` path list that is
  open only during bootstrap (`proxy.gno:157-241`); implementations live at
  `r/gov/dao/impl/v0`; shared data in separate realms (`memberstore/v0`,
  `treasury/v0`) gated by the same allowlist; executors run only when
  `cur.Previous()` is the proxy path (`types.gno:216-233`).
- `r/sys/users` + `r/sys/namereg/v0`: data realm with a GovDAO-managed controller
  allowlist; a new controller is adopted with
  `ProposeControllerAdditionAndRemoval(new, old)` and the data never moves.
- `p/moul/authz/v0`: `Authorizer` whose `Authority` is rotated with
  `Transfer(0, cur, newAuthority)`; `NewMemberAuthority` for a set of addresses,
  `NewContractAuthority(path, handler)` for a DAO; the principal it checks is
  always `cur.Previous().Address()`. Its godoc warns that a wrong
  contract path is a permanent brick and that an executor's `Previous()` is the
  DAO *proxy* path `gno.land/r/gov/dao`, never the impl (`authz.gno:405-414`).
  `r/gnops/valopers/admin.gno:134-191` is the worked rotation entry point.
- onbloc `gno-ibc` (`~/src/onbloc/gno-ibc/gno.land/r/onbloc/ibc/union/core` and
  `apps/ucs03_zkgm`): an IBC-specific version of the same pattern. Proxy owns a
  `Store` exposed to the impl through an `IStore` interface whose setters take
  `(_ int, rlm realm, ...)` and assert `rlm.IsCurrent()`; `RegisterImpl` from the
  impl's `init`, `UpdateImpl` behind an access manager; gated `Emit*` wrappers;
  pause flag checked in every entry point; voucher ledgers kept in the app proxy
  "so their mint/burn rights survive impl upgrades" (`voucher.gno`).

## 4. Options

| Option | Keeps params namespace | Keeps event pkg_path | Keeps address, escrow, vouchers | Relayer config unchanged | State migration needed |
|---|---|---|---|---|---|
| A. Redeploy at `.../v2`, migrate state | no | no | no | no | yes, large |
| B. Permanent proxy + swappable implementation, non-crossing delegation | yes | yes | yes | yes | no |
| C. Data realm + controller allowlist (sys/users style) | yes if data realm writes params | only for emits in the data realm | yes | depends | no |
| D. `private = true` realms | n/a | n/a | n/a | n/a | impossible: unimportable, objects cannot be stored elsewhere |
| E. Status quo, rely on `RecoverClient` / new clients | yes | yes | yes | yes | n/a, but fixes only client *state*, never code |

**Decision: B**, for both core and transfer. C is B with the entry points
moved to the controller; because rows 1 to 3 of §2 pin the entry points and the
param writes to one path, B is the only shape that keeps the whole on-chain
contract. A proxy replacement (A) is a separate, broader decision than the
implementation upgrades covered here and is out of scope.

The delegation **must be non-crossing** (`mustImpl().X(0, cur, ...)`): a crossing
call into the impl would make the impl the current realm, so params would land
under the impl's prefix and grc20 tellers would be refused (`CallerTeller` is
pinned to the token's home realm, `gno-security-guide.md:186`).

## 5. Target architecture

### 5.1 Core proxy (`gno.land/r/aib/ibc/core`, permanent)

The `chore/proxy` branch already implements most of this against a July base.
What follows is that design plus the gaps its own "Next steps" lists and what the
onbloc reference adds.

Frozen surface, never changes after mainnet deploy:

1. **Entry points**, exact current signatures, thin dispatchers to the active
   `Logic` (non-crossing). The relayer and e2e stay untouched apart from the `/v0`
   import rename of §5.5; filetests gain only the blank import of §5.6.
2. **Store** owned by the proxy, exposed to implementations as an interface
   (`IStore`-style). Every mutator takes `(_ int, rlm realm, ...)` and asserts
   `rlm.IsCurrent() && rlm.PkgPath() == corePkgPath`; readers are plain. Needed
   accessors, from today's usage in `store.gno`: `AddClient`, `Client(id)` handle
   with `ID/Type/Creator/Counterparty/SetCounterparty/LightClient/SetLightClient/
   NextSendSequence`, commitment get/set/delete, receipt has/set/delete, ack
   has/get/set/delete, pending async ack save/get/delete, `ClientIDs`,
   `Route(port)`. The proxy keeps the only `params.SetBytes` calls, inside the
   commitment/receipt/ack setters. Because `client` is a core-declared type, the
   proxy must provide the constructors (impl code cannot build `&client{}`).
3. **Gated `Emit*` wrappers**, single source of truth for the event schema
   (`emit.gno` on the branch), guarded by the same realm assertion.
4. **Authorization gates hoisted into the dispatchers**: `ensureAuthorizedRelayer`
   and the authority check run in the frozen proxy before delegating, so a buggy
   implementation cannot drop them. `CreateClient` passes the relayer address into
   `Logic` since it is recorded as `creator`.
5. **App registry unchanged**: `RegisterApp` stays as on master. No
   authority-gated `ReplaceApp` or `UnregisterApp`: not needed for the transfer
   upgrade path (the registered value is the transfer proxy forever); why they
   could still be useful is recorded in issue #59.
6. **No light-client code in the proxy.** Today `addClient` hardwires
   `tendermint.NewTMLightClient()`. In the proxy design the implementation
   constructs the verifier it imports and hands the object to the store
   (`AddClient(0, rlm, typ, creator, lc)`, as onbloc does); the proxy only holds
   the `lightclient.Interface` value per client and exposes `SetLightClient` for
   migrations. Changing the verifier is therefore an ordinary implementation
   upgrade, with no separate admin operation and no function-valued argument.
7. **Implementation lifecycle**: `RegisterImpl(cur, ctor)` callable only from a
   sub-realm of the proxy path (`gno.land/r/aib/ibc/core/impl/vN`), records a
   constructor; `UpdateImpl(cur, path)` authority-gated, builds the impl against
   the proxy store, calls the impl's `OnInstall(0, cur, prevPath, prevVersion)`
   hook, emits
   `impl_updated{old,new,version}`; `ImplPath()` and `ImplVersion()` readers;
   rollback is `UpdateImpl(previousPath)`. Bootstrap rule mirroring `r/gov/dao`'s
   empty `allowedDAOs`: the first registration while no impl is installed
   auto-activates (so genesis needs no extra tx and filetests need only a blank
   import, see §5.6); every later switch requires `UpdateImpl`.
8. **Authority** (§5.4) replacing the raw `admin` address; `SetAdmin` is replaced
   by membership entry points (`AddAuthorityMember`, `RemoveAuthorityMember`).
9. **Render** showing "upgradeable realm", the active impl path and version, and
   the authority, per the Constitution's disclosure rule.

`Logic` interface (the branch's `upgrade.gno`, extended):

```gno
type Logic interface {
    Version() string
    OnInstall(_ int, rlm realm, prevPath, prevVersion string) // migration hook, runs inside UpdateImpl
    CreateClient(_ int, rlm realm, relayer address, cs lightclient.ClientState, cons lightclient.ConsensusState) string
    RegisterCounterparty(_ int, rlm realm, ...)
    UpdateClient(_ int, rlm realm, ...)
    UpgradeClient(_ int, rlm realm, ...)
    RecoverClient(_ int, rlm realm, ...)
    SendPacket(_ int, rlm realm, msg types.MsgSendPacket) uint64
    RecvPacket(_ int, rlm realm, msg types.MsgRecvPacket) types.ResponseResultType
    WriteAcknowledgement(_ int, rlm realm, ...)
    Acknowledgement(_ int, rlm realm, ...) types.ResponseResultType
    Timeout(_ int, rlm realm, ...) types.ResponseResultType
}
```

`OnInstall` is the migration hook, the equivalent of a CosmWasm `migrate` entry
point. It runs inside `UpdateImpl` after the impl is built against the store and
before any entry point reaches it, so a panic aborts the switch atomically. It
must be idempotent and schema-aware (it runs again on re-install and on rollback;
a schema version in the store lets an impl refuse a store it does not understand)
and cheap: at most linear in the number of clients, with anything proportional to
packets left to lazy conversion on access. A migration that is not additive
forfeits rollback.

Forward compatibility of the surface itself. Callers only ever talk to the proxy:
the relayer, the apps (`SendPacket`, `WriteAcknowledgement`, `RegisterApp`),
tools and users. No implementation realm exports a mutating entry point, so the
proxy's entry-point set is the complete external API for the life of the realm.
That is acceptable because the set equals the IBC v2 message set, which is small
and finished, provided the frozen signatures leave room to grow:

- Interface-typed parameters (`lightclient.ClientState`, `ClientMessage`,
  `app.IBCApp`) are open: a later `/v1` type implements the `/v0` interface and
  the implementation type-asserts for anything newer. `UpgradeClient` already
  takes `any` proofs.
- Struct-typed messages are not: the `p/aib/ibc/types` structs are immutable and
  the proxy signatures pin their `/v0` version. Before the freeze, each `Msg*`
  struct (`MsgSendPacket`, `MsgRecvPacket`, `MsgAcknowledgement`, `MsgTimeout`)
  gets an `Ext any` field, unused by `impl/v0`, through which a later
  implementation can receive new data on the existing entry points. `Packet`
  itself is committed on both chains and stays as it is.
- A genuinely new message type is a new IBC protocol version, not an upgrade: it
  would mean a new proxy at a new path, a relayer release and a counterparty
  re-registration (option A of §4). Accepted as out of scope for in-place
  upgrades.

Implementation realms may export read-only helpers (render, queries) on their own
path; nothing that mutates, writes params, emits or needs authority. A
stringly-typed `Call(cur, op string, args ...any)` escape hatch on the proxy was
considered and decided against (§8): it trades type safety and per-operation
gates for a flexibility the `Ext` fields provide more narrowly.

### 5.2 Light clients

Light-client *state* is a set of core-owned objects whose methods are bound to the
`/p/` version that created them. Upgrading verification logic for existing clients:

- Keep verification in `/p/` (immutable, auditable), versioned
  `p/aib/ibc/lightclient/tendermint/v0`, `/v1`, ...
- A new core implementation that needs the new verifier migrates each client
  lazily or in `OnInstall`: read the exported fields of the stored v0
  `*TMLightClient` (`ClientState`, `ConsensusStateByHeight` are already exported),
  wrap or convert them with `tendermint/v1.FromV0(...)`, and store the result via
  `SetLightClient`. The `bptree` of consensus states can be shared by pointer, so
  the migration is O(1) per client.
- New clients get the new verifier simply because the new implementation
  constructs it.
- The store field is typed `lightclient/v0.Interface` forever, so a later
  `lightclient/v1` verifier must still implement the v0 methods; the
  implementation type-asserts for anything newer.
- `RecoverClient` and a brand-new client remain the fallback when the state
  itself must change shape (counterparty re-registration required).

### 5.3 Transfer proxy (`gno.land/r/aib/ibc/apps/transfer`, permanent)

Same shape, same reasons (rows 4 and 5 of §2 are the strongest in the table).

Frozen surface:

- `Transfer`, `VoucherSend`, `VoucherApprove`, the read helpers
  (`VoucherBalanceOf`, `VoucherSymbol`, `GRC20Alias`, `NewToken`, `NewDenom`...)
  and `Render`, all delegating non-crossing where logic is involved.
- `App` implementing `app.IBCApp`, registered once in `init` as today; each
  callback keeps its core-caller assertion (PR #60) and forwards non-crossing to
  the impl.
- The direct-user-call guards (`cur.Previous().IsUserCall()`,
  `transfer.gno:274,301,331`) and `OriginSend` handling stay in `Transfer`; the
  non-crossing forward preserves `cur.Previous()`, so the impl sees the same facts.
- Store, proxy-owned: `denoms`, per-client escrow accounting, `voucherTokens`
  (token plus `PrivateLedger`, never returned to callers), `nextVoucherID`, the
  three `pending*` slots. Exposed through guarded accessors; the ledger pointer is
  only ever used inside proxy code (`Mint/Burn` helpers taking `rlm`).
- Value-moving services in the proxy, taking `rlm`: `banker.NewBanker(RealmSend,
  rlm)` sends, grc20 `RealmTeller(0, rlm)` transfers, voucher mint/burn,
  `grc20reg.Register(cross(rlm), ...)`. They work because the current realm is
  the proxy, the token's home realm.
- Authority, `RegisterImpl/UpdateImpl`, Render disclosure, as in core.

Implementation realm: `gno.land/r/aib/ibc/apps/transfer/impl/v0` holding the
ICS-20 logic (`OnSendPacket`, `OnRecvPacket`, refund paths, denom tracing).

### 5.4 Authority (#36)

Replace the single `admin` EOA in both proxies with a `p/moul/authz/v0`
`Authorizer`. Three facts of that package shape the design (`authz.gno:181-233`):

- The principal is the *caller's address*, `cur.Previous().Address()`, not the
  transaction signer. A direct `maketx call` from the multisig presents the
  multisig; a call routed through another realm, or through `maketx run`,
  presents that realm's address and fails. Every gated operation is therefore a
  direct `MsgCall` with scalar arguments (path strings, addresses).
- GovDAO never calls a realm directly; it executes a callback. Inside a callback
  *declared in our proxy*, `cur.Previous()` is `gno.land/r/gov/dao`, so the DAO's
  address is the principal. The callback must reach the gated logic non-crossing
  (an internal `updateImpl(0, cur, path)`): a same-package `cross()` would make
  the proxy itself the previous realm. Consequently the proposal-request
  constructors (`NewUpdateImplProposalRequest(cur, path)`, one per gated
  operation) live in the frozen proxy, not in an implementation realm; a callback
  declared in `impl/v0` would present `impl/v0` as the principal. The callbacks
  stay unexported and out of the `func(realm) error` shape, which the authz godoc
  identifies as the capability leak.
- The DAO proxy path is a safe principal only because `SimpleExecutor.Execute`
  refuses to run from outside `r/gov/dao` (`types.gno:216-233`).

Bootstrap (decided): one `MemberAuthority` with two members from `init`, the
deployer EOA, which is the AIB multisig (`g1gkqe9c90tfuk2a7f07ygs8t826aff03vxasjsl`), and
`chain.PackageAddress("gno.land/r/gov/dao")`. The multisig calls the gated
operations directly; GovDAO reaches them through the proxy-declared callbacks.
This is the "in addition to" reading of #36. `RemoveAuthorityMember(multisig)`
later makes the authority DAO-only without a `Transfer`; until then the multisig
is also the recovery path if the DAO proxy is ever superseded.

Gated operations: `UpdateImpl`,
`AddRelayer/RemoveRelayer`, `RecoverClient`, and the
authority's own membership (`AddAuthorityMember/RemoveAuthorityMember`, each
authorized by an existing member). The relayer whitelist stays
`unsafe.OriginCaller`-based for the high-frequency relayer operations, as #36
scopes.

No timelock between `RegisterImpl` and `UpdateImpl` (decided). The two-step
itself stays: a candidate is visible in `Render` and events from the moment it
registers, and only the authority can activate it.

Not chosen: the "replace" shape, where `Transfer` moves the authority to a
`NewContractAuthority` on the DAO proxy path as `r/gnops/valopers` does. After
such a transfer the multisig has no authority left, every gated call runs only
from a passed proposal, and a wrong path bricks the realm. `Transfer` is
therefore not exposed by the proxies at all: the authority stays a canonical
member set, and the only thing governance can change is who the members are.

The e2e suite should exercise a GovDAO-driven `UpdateImpl` through the proposal
constructors against a real `r/gov/dao` once before mainnet.

### 5.5 Versioning and layout

Follow the gno examples: stable entry realms unversioned, everything else `/vN`.

```
gno.land/r/aib/ibc/core                     proxy (permanent)
gno.land/r/aib/ibc/core/impl/v0             first implementation
gno.land/r/aib/ibc/apps/transfer            proxy (permanent)
gno.land/r/aib/ibc/apps/transfer/impl/v0    first implementation
gno.land/p/aib/ibc/types/v0, host/v0, lightclient/v0, lightclient/tendermint/v0, ...
```

- Shared types stay in `/p/` so every implementation version can construct them.
- Adding `/v0` to the `p/aib/...` paths is a one-time rename of imports that is
  only possible before mainnet (decided). It costs nothing on-chain, matches
  nearly every `examples/` package, and is what lets a `types/v1` coexist later.
  It is not invisible to callers, though: every `MsgRun` script that imports
  those packages must be updated once. That includes the ts-relayer templates,
  which import `p/aib/ibc/types`, `p/aib/ibc/lightclient/tendermint` and
  `p/aib/ics23` to build their arguments, so a relayer release has to ship before
  or with the renamed packages. `MsgCall` callers (`Transfer`, voucher helpers,
  admin operations) and `vm/qrender` / `vm/qeval` queries are unaffected.
- Implementation realms keep no state of their own beyond the injected store
  reference, so abandoning one wastes no storage deposit.

### 5.6 Where the genesis logic lives (decided: external)

ADR 0001 kept the v0 logic *inside* the proxy package as a `defaultLogic`, active
without wiring, with only future versions external. That part of the ADR is not
followed. It carried a cost the ADR itself noted: the external-impl contract (the
exported store surface) is never exercised until the first real upgrade, and
in-package code can quietly use unexported internals.

Instead, as onbloc and `r/gov/dao` do, the proxy has **no** logic:
`core/impl/v0` is a real external realm from day one.

- Every one of the 182 filetests and the e2e flow then runs through the exported
  surface, so the frozen surface is proven complete before it freezes.
- The proxy stays minimal, and no obsolete v0 logic is frozen into it forever.
- Cost: one blank import `_ "gno.land/r/aib/ibc/core/impl/v0"` per filetest (the
  auto-activation bootstrap of §5.1 item 7 means no `UpdateImpl` call in tests),
  no golden-output change (filetests record events emitted from `main`, not from
  package `init`), and the impl paths added to `-paths` in `Makefile` and
  `e2e/gno/entrypoint.sh`, and to `scripts/packages.sh`.

### 5.7 Upgrade runbook

1. Build `impl/vN`. Run `make test`, then e2e with `vN` active.
2. `addpkg` the implementation. On mainnet it parks inert until gpao approves; its
   `init` (hence `RegisterImpl`) runs at enable time.
3. Verify the candidate appears in `Render` (registered, not active).
4. `UpdateImpl(path)` through the authority: a direct `MsgCall` from the
   multisig, or a GovDAO proposal built with the proxy's request constructor
   (anyone may execute a passed proposal; if it is executed before step 2 has
   completed, the proxy's panic aborts the transaction and the proposal stays
   executable). `OnInstall` runs any migration; `impl_updated` is emitted.
   In-flight packets need no draining: commitments, receipts and acks live in
   the proxy and stay provable across the switch.
5. Smoke test: one `UpdateClient` by the relayer, one transfer in each direction.
6. Rollback at any point: `UpdateImpl(previousPath)`.

No relayer, counterparty or user-facing change is needed for an upgrade. A
verifier change (§5.2) and a transfer upgrade are ordinary implementation
upgrades and follow the same steps.

## 6. Phased delivery

**Phase 0, decisions and ADRs.** Rewrite ADR 0001 on master, using the
`chore/proxy` branch as a reference rather than rebasing it (the branch predates
the mainnet update `#58` and the `v1.5.0` pin), add ADR 0002
(transfer proxy) and ADR 0003 (authority model); mark ADR 0001's in-package
`defaultLogic` as superseded (§5.6). Record the decisions of §8.

**Rename to `/v0` (before Phase 1).** Move every `p/aib/...` package to its
`/v0` path (§5.5) and update all imports, the README `run.gno` examples and the
filetests, and add the `Ext any` field to the `Msg*` types (§5.1) in the same
change, since it is the last chance to touch them. Coordinate a ts-relayer
release that updates its templates' imports: until both sides are deployed, the
relayer cannot talk to the renamed packages.

**Phase 1, core proxy.** Port `upgrade.gno`, `emit.gno`, the dispatchers and
`proxy_test.gno` from `chore/proxy`; export the store surface with the realm gate;
hoist the relayer and authority gates into the dispatchers; add
`Version` / `OnInstall`, the auto-activation bootstrap, Render disclosure. Move the logic to
`core/impl/v0`; the proxy keeps no `defaultLogic`. Tests: unit tests for every
gate (foreign realm, non-current realm, unregistered path, non-authority), a new
filetest category `z11*` for implementation switch and rollback, and the existing
182 golden outputs byte-identical.

**Phase 2, transfer proxy.** Same treatment: store and voucher/escrow services in
the proxy, callbacks forwarding non-crossing, `impl/v0`. New filetest category `z6*` (impl switch, refund after switch, voucher
balances preserved across a switch).

**Phase 3, authority.** `authz` in both proxies; the proposal-request
constructors and their unexported callbacks in the proxies (§5.4), one per gated
operation; membership entry points; e2e exercising a GovDAO-driven `UpdateImpl`
through the proposal constructors against a real `r/gov/dao`. Closes #36.

**Phase 4, upgrade rehearsal and tooling.** A throwaway `core/impl/v99` and
`transfer/impl/v99` differing only by `Version()` (a version suffix must match
`v<N>`, so a name like `v1-test` is not one); an e2e job that deploys
them into the running gnodev, switches, reruns both transfer tests, rolls back;
`packages.sh` entries (used by `deploy.sh` and `make-deploy-tx.sh`); `make gnodev` paths; the runbook as
`docs/upgrade-runbook.md`; relayer-facing note that paths and events are stable.

**Phase 5, mainnet readiness.** Freeze review of the proxy surface against this
document (every item of §5.1 and §5.3 present), external review of the gates, pin
bump checklist entry "re-verify params and emit attribution" (see §7), gnoweb
disclosure text, README updates.

Rough sizes: Phase 1 is the largest (two to three weeks including tests, half of it
already drafted on the branch), Phase 2 about the same, Phases 3 to 5 a week each.

## 7. Risks and open points

- **Frozen surface incomplete.** The single biggest risk; it is why §5.6 puts
  the logic in an external `impl/v0` from day one and why §5.1 keeps the
  signatures open (interfaces, `any` proofs, `Ext` fields).
- **The active implementation is fully trusted.** `UpdateImpl` is total control
  over IBC state and escrow. Mitigation: authority held by the AIB multisig and
  GovDAO as a two-member set, with the membership entry points in the frozen
  surface so the multisig can be removed once the DAO path is proven.
- **Runtime semantics drift.** The attribution facts of §3 are VM internals.
  `execctx/realm.go` on HEAD already describes "presented identities" and
  sub-realm tokens that did not exist when ADR 0001 was written; they do not change
  the conclusions, but each pin bump should re-run the golden filetests (events are
  byte-compared) and the e2e proof verification (which fails if the params prefix
  moves). Add this to the `make update-fork` checklist.
- **Inert deploys reorder initialization.** `RegisterImpl` runs when the approver
  enables the impl, so the proxy must be enabled first and the bootstrap
  auto-activation must tolerate an arbitrary delay. Any later impl is inert until
  approved and then still inactive until `UpdateImpl`; this is the desired
  two-step.
- **`MsgRun` allowlisting on mainnet.** Adjacent to upgradability: the relayer's
  calls are `MsgRun` templates, so the relayer key may need to be in
  `run_submitters`. Keeping every governance entry point `MsgCall`-compatible
  keeps *upgrades* out of that problem.
- **GovDAO request API frozen into the proxy.** The proposal-request
  constructors build `r/gov/dao` requests, so a superseded DAO proxy or a changed
  request type leaves them dead. The multisig member is the recovery path;
  removing it (making the authority DAO-only) also removes that recovery, so the
  removal should wait until the DAO path has been exercised on mainnet.

## 8. Decisions

Decided (2026-10-01):

- Genesis logic lives in an external `core/impl/v0`; the proxy has no in-package
  `defaultLogic` (§5.6).
- All `p/aib/...` paths get a `/v0` suffix before mainnet (§5.5).
- Bootstrap authority is a member set holding the deployer EOA, which is the AIB
  multisig, and the GovDAO proxy address. No timelock knob (§5.4).
- The work is re-implemented on master, with the `chore/proxy` branch used as a
  reference rather than rebased (Phase 0).
- No generic `Call` escape hatch on the proxies, and no mutating entry point
  outside them: callers only ever talk to the proxy. Growth happens through the
  open parameter types and the `Ext` fields; a new message type is a new protocol
  version (§5.1).
- GovDAO is a member of that set from day one (the "both" shape of #36) rather
  than replacing the multisig; authz's `Transfer` is not exposed (§5.4).

Open: none.
