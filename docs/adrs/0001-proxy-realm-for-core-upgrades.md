# ADR 0001: Proxy realm for upgradeable IBC core

- Status: Accepted
- Date: 2026-10-05
- Issue: [#22](https://github.com/allinbits/gno-realms/issues/22) (Use proxy realms)
- Plan: [`docs/upgradability-plan.md`](../upgradability-plan.md)
- Deciders: @tbruyelle

## Context

Gno realms are immutable. `MsgAddPackage` on an existing public path fails and
the VM has no upgrade, replace or migrate message. The core realm
`gno.land/r/aib/ibc/core` holds the client and packet lifecycle, which will need
bug fixes and feature changes after it is deployed, while four things bound to
its path must never change:

1. **Chain-param namespace.** Packet commitments, receipts and acknowledgements
   are mirrored into chain params so the counterparty can prove them. The key is
   `vm:<current realm>:<key>`, where the current realm is the realm of the most
   recent crossing frame (`chain/params.pkey` via `execctx.CurrentRealm`). The
   AtomOne `10-gno` light client derives its proof paths from
   `vm:gno.land/r/aib/ibc/core:`.
2. **Event `pkg_path`.** `chain.Emit` stamps the package whose code contains
   the call, not the current realm. The ts-relayer finds packets through these
   events, so they must keep `pkg_path = gno.land/r/aib/ibc/core`.
3. **Entry-point path and signatures.** The relayer's `MsgRun` templates import
   the core path and call `CreateClient`, `UpdateClient`, `RegisterCounterparty`,
   `SendPacket`, `RecvPacket`, `Acknowledgement`, `Timeout`, `WriteAcknowledgement`,
   `UpgradeClient` and `RecoverClient` with their current signatures.
4. **Registered apps.** Apps register their realm value under a port; the
   transfer realm holds escrow and voucher ledgers keyed to the core that calls
   it back.

The two attributions use different mechanisms (params follow crossing, emits
follow code location), so the design has to guarantee both separately: params
are written while core is the current realm, and emits run from code inside the
core package.

Master also has a member authority (`p/aib/authority`, the AIB multisig plus
the GovDAO proxy) that gates every administrative operation, GovDAO proposal
constructors, a core-wide pause, per-app pause, and authority-approved app
registrations. The proxy design has to carry all of it.

## Decision

`gno.land/r/aib/ibc/core` becomes a permanent, thin **proxy**. The lifecycle
logic lives in a separate implementation realm behind a `Logic` interface and
is invoked **non-crossing**, so the current realm stays the proxy for the whole
call. The first implementation is `gno.land/r/aib/ibc/core/impl/v0`; the proxy
contains no logic of its own, so the exported surface is exercised from day one
and nothing can quietly rely on unexported internals.

### Frozen surface

Nothing in this list can change after the first mainnet deploy.

1. **Entry points** with their exact current signatures, forwarding to
   `mustImpl().X(0, cur, ...)`. Every public read helper (`ClientIDs`,
   `ClientStatus`, `ClientLatestHeight`, `IsAppPending`, `IsAppPaused`,
   `IsAuthorityMember`, `Paused`, `Render`) stays in the proxy.
2. **Gates run in the proxy before delegating**: `ensureAuthorizedRelayer`
   (client operations and packet relaying), `ensureNotPaused` (packet path),
   and the authority assertion for administrative operations. A buggy
   implementation cannot drop them. `CreateClient` passes the relayer address
   into `Logic`, since the implementation records it as `creator`.
3. **Administration stays in the proxy**: authority membership, relayer
   whitelist, `Pause`/`Unpause`, `RegisterApp`/`ApproveApp`/`RejectApp`,
   `PauseApp`/`UnpauseApp`, every `New*ProposalRequest` constructor. They are
   small, `MsgCall`-compatible, and they are the gates themselves.
4. **Store owned by the proxy**, exposed to implementations as an interface
   (`Store`). Every mutator takes `(_ int, rlm realm, ...)` and asserts
   `rlm.IsCurrent() && rlm.PkgPath() == corePkgPath`; readers are plain.
   Accessors, from today's usage: `AddClient` (the `client` type is
   core-declared, so only the proxy can build it), a client handle with
   `ID/Type/Creator/Counterparty/SetCounterparty/LightClient/SetLightClient/
   NextSendSequence`, commitment get/set/delete, receipt has/set/delete, ack
   has/get/set/delete, pending async ack save/get/delete, `ClientIDs`,
   `Route(port)` (entry with its `paused` flag). The proxy keeps the only
   `params.SetBytes` calls, inside the commitment, receipt and ack setters.
5. **Gated `Emit*` wrappers**, one per lifecycle event type of `p/aib/ibc/types`,
   guarded by the same realm assertion. They are the single source of truth for
   the event schema. Administrative events are emitted by proxy code directly.
6. **No light-client code in the proxy.** The implementation chooses the
   verifier and hands its `/p/` constructor to `AddClient(0, rlm, typ,
   creator, newLightClient)`; the proxy calls it, so the verifier is allocated
   in the proxy's storage rather than the implementation's, and stores it as a
   `lightclient.Interface`. Changing the verifier is an
   ordinary implementation upgrade (see "Light clients").
7. **Implementation lifecycle.**
   - `RegisterImpl(cur, ctor func(Store) Logic)`: callable only from a sub-realm
     of the proxy path (`gno.land/r/aib/ibc/core/impl/vN`), from the
     implementation's `init`. Registration activates nothing, except the
     bootstrap case below.
   - `UpdateImpl(cur, path)`: authority-gated. Builds the implementation against
     the proxy store, calls `OnInstall(0, cur, prevPath, prevVersion)`, then
     swaps and emits `impl_updated{old, new, version}`. A panic in `OnInstall`
     aborts the switch. Rollback is `UpdateImpl(previousPath)`.
   - `NewUpdateImplProposalRequest(cur, path)` next to the other constructors.
     It must live in the proxy: a callback declared in an implementation realm
     would present that realm, not the DAO proxy, as the caller.
   - Bootstrap: the first registration while no implementation is installed
     auto-activates, mirroring `r/gov/dao`'s empty `allowedDAOs`. Genesis needs
     no extra transaction and filetests need only a blank import of `impl/v0`.
   - `ImplPath()` and `ImplVersion()` readers.
8. **Render** is forwarded to `Logic.Render`, JSON routes included: a route
   frozen in the proxy could not follow the verifier it reads across a
   light-client migration. The routes the relayer reads through `vm/qrender`
   (`clients/{id}`, its consensus states, packet commitments and receipts)
   are a compatibility contract pinned by the `z0c` filetest, so a shape
   change surfaces as a failing test and requires a relayer release. The
   implementation paginates over read-only views of the proxy's trees
   (`bptree.ITree` with panicking mutators), never the trees themselves,
   which would be a write capability. The home page discloses "upgradeable
   realm", the active implementation path and version, and the admin page
   the authority members (Constitution, "Realm Upgrading").

### `Logic`

```gno
type Logic interface {
    Version() string
    OnInstall(_ int, rlm realm, prevPath, prevVersion string)
    Render(path string) string // every route; the relayer-read ones are pinned by z0c
    CreateClient(_ int, rlm realm, relayer address, cs lightclient.ClientState, cons lightclient.ConsensusState) string
    RegisterCounterparty(_ int, rlm realm, clientID string, counterpartyMerklePrefix [][]byte, counterpartyClientID string)
    UpdateClient(_ int, rlm realm, clientID string, clientMessage lightclient.ClientMessage)
    UpgradeClient(_ int, rlm realm, clientID string, clientState, consensusState, proofUpgradeClient, proofUpgradeConsensusState any)
    RecoverClient(_ int, rlm realm, subjectClientID, substituteClientID string)
    SendPacket(_ int, rlm realm, msg types.MsgSendPacket) uint64
    RecvPacket(_ int, rlm realm, msg types.MsgRecvPacket) types.ResponseResultType
    WriteAcknowledgement(_ int, rlm realm, clientID string, sequence uint64, ack types.Acknowledgement)
    Acknowledgement(_ int, rlm realm, msg types.MsgAcknowledgement) types.ResponseResultType
    Timeout(_ int, rlm realm, msg types.MsgTimeout) types.ResponseResultType
}
```

`OnInstall` is the migration hook. It runs inside `UpdateImpl` before any entry
point reaches the new implementation, with the version that was active as
`prevVersion`, which is also the layout of the data as long as versions
activate in sequence. Its contract: do nothing when `prevVersion` is its own
version, migrate when it is the version it follows, panic otherwise. A panic
aborts the whole transaction, so the previous implementation stays active and
nothing the hook wrote persists; a fix then ships as the next version, whose
hook is installed over the still-active one. The migration must be cheap: at
most linear in the number of clients, with anything proportional to packets
left to lazy conversion on access. A migration that is not additive forfeits
rollback.

### What an implementation may and may not do

- It runs as the proxy: `rlm` is the proxy's live realm value, `rlm.Previous()`
  is the proxy's caller (so the `WriteAcknowledgement` app gate and the
  `OriginCaller`-based relayer identity see the same facts as today), and app
  callbacks are issued with `cross(rlm)`, so apps keep seeing the core path as
  their caller (PR #60's `assertCoreCaller`).
- It writes state only through the `Store` accessors, emits only through the
  `Emit*` wrappers, and honors the per-app `paused` flag it reads from
  `Route(port)` (refuse sends, answer receives with the error acknowledgement).
- It exports no mutating entry point, writes no params, emits nothing and needs
  no authority on its own path. Read-only helpers for render or queries are
  allowed. Its `init` must not write params: at `init` the current realm is the
  implementation itself, so the key would land under the wrong prefix.
- It keeps no state of its own beyond the injected store reference, so an
  abandoned implementation wastes no storage deposit.

### Light clients

Light-client state is a set of core-owned objects whose methods are bound to
the `/p/` version that created them. Verification stays in `/p/`, versioned
(`p/aib/ibc/lightclient/tendermint/v0`, `/v1`, ...). A new implementation that
needs a new verifier converts each stored client lazily or in `OnInstall`,
reading the exported fields of the v0 object and storing the result with
`SetLightClient`, which takes the `/p/` conversion function for the same
allocation reason as `AddClient`; the consensus-state tree can be shared by pointer, so the
migration is O(1) per client. The store field stays typed
`lightclient.Interface` forever, so a later verifier such as `tendermint/v1`
must still implement it and the implementation type-asserts for anything newer. `RecoverClient` and a
new client remain the fallback when the state itself must change shape.

### Surface freeze and room to grow

Callers only ever talk to the proxy: the relayer, the apps, tools and users. No
implementation exports a mutating entry point, so the proxy's entry-point set is
the complete external API for the life of the realm. That is acceptable because
it equals the IBC v2 message set, provided the frozen signatures leave room:

- Interface-typed parameters (`lightclient.ClientState`, `ClientMessage`,
  `app.IBCApp`) are open: a later `/v1` type implements the `/v0` interface and
  the implementation type-asserts for anything newer. `UpgradeClient` already
  takes `any` proofs.
- Struct-typed messages are not. Before the freeze, each `Msg*` struct of
  `p/aib/ibc/types` (`MsgSendPacket`, `MsgRecvPacket`, `MsgAcknowledgement`,
  `MsgTimeout`) gets an `Ext any` field, unused by `impl/v0`, through which a
  later implementation can receive new data on the existing entry points.
  `Packet` itself is committed on both chains and stays as it is.
- A genuinely new message type is a new IBC protocol version: a new proxy at a
  new path, a relayer release and a counterparty re-registration. Out of scope
  for in-place upgrades.

### Versioning and layout

```
gno.land/r/aib/ibc/core                     proxy (permanent)
gno.land/r/aib/ibc/core/impl/v0             first implementation
gno.land/p/aib/ibc/types/v0, host/v0, lightclient/v0, lightclient/tendermint/v0, ...
```

Every `p/aib/...` package gets a `/v0` suffix before mainnet, in one rename that
also adds the `Ext` fields. Shared types stay in `/p/` so every implementation
version can construct them. The rename is visible to `MsgRun` callers, including
the ts-relayer templates, so a relayer release ships before or with it.

### Gating `UpdateImpl`

`UpdateImpl` joins the operations gated by `p/aib/authority`: a direct `MsgCall`
from the multisig, or a GovDAO proposal built with the proxy's constructor. No
timelock between `RegisterImpl` and `UpdateImpl`. The two-step itself stays: a
candidate is visible in `Render` and in events from the moment it registers,
and only the authority can activate it.

## Consequences

Positive:

- Core logic is upgradeable without changing the entry-point path, the event
  `pkg_path` or the chain-param namespace. No relayer, counterparty or user
  change is needed for an upgrade, and in-flight packets need no draining:
  commitments, receipts and acks live in the proxy and stay provable across the
  switch.
- The exported store and emit surface is exercised by every filetest and by the
  e2e flow from day one, since even `impl/v0` goes through it. The frozen surface
  is proven complete before it freezes.
- Golden filetest outputs are byte-compared, which makes them the regression
  guard for the attribution invariants on every pin bump.

Negative:

- **Frozen surface.** Any accessor, event or hook a future implementation needs
  must exist in the proxy before mainnet. The pre-mainnet freeze review checks
  this document item by item.
- **The active implementation is fully trusted.** `UpdateImpl` is total control
  over IBC state. It is gated by the authority, whose membership can be narrowed
  to GovDAO once the DAO path is proven; the multisig member is also the recovery
  path if the frozen `r/gov/dao` request API is ever superseded.
- **Runtime semantics are VM internals.** The attribution rules above were
  verified against `gnolang/gno v1.5.0` (source and a two-realm probe). Each pin
  bump re-runs the golden filetests and the e2e proof verification.
- **Inert deploys reorder initialization.** On a chain with
  `code_submission_policy = inert`, `RegisterImpl` runs when the approver enables
  the implementation, so the proxy must be enabled first and the bootstrap must
  tolerate an arbitrary delay.

## Alternatives considered

- **Redeploy core at a new path and migrate state.** Breaks the param
  namespace, the event `pkg_path` and the relayer configuration, and requires a
  counterparty re-registration. Rejected.
- **Data realm plus controller allowlist** (`r/sys/users` style). Equivalent to
  the proxy with the entry points moved to the controller; since the entry points
  and the param writes are pinned to one path, it does not keep the whole
  contract. Rejected.
- **`private = true` realms.** Redeployable, but unimportable and their objects
  cannot be stored elsewhere. Core is imported by transfer. Rejected.
- **Status quo, `RecoverClient` and new clients.** Fixes client *state*, never
  code. Rejected.
- **Crossing delegation** (`impl.X(cross(cur), ...)`). Would make the
  implementation the current realm: params would land under its prefix and the
  grc20 tellers used by transfer would be refused. Rejected.
- **Generic `Call(cur, op string, args ...any)` escape hatch on the proxy.**
  Trades type safety and per-operation gates for a flexibility the `Ext` fields
  provide more narrowly. Rejected.
- **Timelock between `RegisterImpl` and `UpdateImpl`.** Rejected; the authority
  and the visible two-step are enough.
- **Authority-gated `ReplaceApp`/`UnregisterApp`.** Not needed for the
  transfer upgrade path, since the registered value is the transfer proxy
  forever. Why it could still be useful is recorded in issue #59.

## References

- `r/gov/dao`: unversioned proxy storing a `DAO` interface value,
  `UpdateImpl` gated by an `allowedDAOs` list open only during bootstrap,
  implementations at `r/gov/dao/impl/v0`, executors run only when
  `cur.Previous()` is the proxy path.
- onbloc `gno-ibc` `r/onbloc/ibc/union/core`: proxy-owned store behind an
  `IStore` interface whose setters assert `rlm.IsCurrent()`, `RegisterImpl`
  from the implementation's `init`, gated `Emit*` wrappers, pause flag.
- gnovm attribution: `chain/params/params.go` (`pkey`), `chain/emit_event.go`,
  `internal/execctx/realm.go` (`CurrentRealm`), `docs/resources/gno-interrealm.md`
  (borrow rules).
- `docs/CONSTITUTION.md`, "Realm Upgrading": disclosure in gnoweb, no
  upgradeable-realm types persisted in immutable realms, `/p/` never upgraded.
