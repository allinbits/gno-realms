# Upgrade runbook

How to replace the implementation behind `gno.land/r/aib/ibc/core` or
`gno.land/r/aib/ibc/apps/transfer` on a live chain. Background and the
reasons for the shape are in [ADR 0001](adrs/0001-proxy-realm-for-core-upgrades.md)
and [ADR 0002](adrs/0002-proxy-realm-for-transfer-upgrades.md). The e2e
`TestUpgradeRehearsal` runs these steps against gnodev with the `impl/v99`
candidates of `e2e/gno/rehearsal/`.

Nothing outside the chain changes during an upgrade: the realm paths, the
entry points, the events and the render routes are the proxies', and the
relayer, the counterparty chain and the users keep using them. In-flight
packets need no draining: commitments, receipts and acknowledgements live in
the proxies and stay provable across the switch.

## 1. Build and test the candidate

- The candidate is a realm under the proxy's `impl/` namespace,
  `gno.land/r/aib/ibc/core/impl/vN` or
  `gno.land/r/aib/ibc/apps/transfer/impl/vN` (the suffix must be `v<N>`). It
  implements the proxy's `Logic`, registers itself from `init` with
  `RegisterImpl`, and reuses from `impl/v0` what it does not change (`New`, the
  exported `Renderer`).
- `RegisterImpl` takes, beside the constructor, a manifest of plain
  values: `RegisterImpl(cur, ctor, version, over)` for the core,
  `RegisterImpl(cur, ctor, version, over, keepsControls)` for the transfer
  app. `version` is what the candidate's `Version()` reports; `over` lists
  the versions of an active implementation it installs over (`""` for the
  bootstrap; its own version is always accepted; `nil` accepts any);
  `keepsControls` declares that it implements the route controls. The
  governed preflight (`CheckUpdateImpl`) checks the manifest, then runs the
  candidate's constructor against a fresh, empty store (never the live
  one), checks the version it builds (and, for transfer, whether it keeps
  the controls) against the manifest, and evaluates its declared install
  condition (`CheckInstall`): candidate code runs during the preflight. The
  installation checks the built candidate against its manifest again and
  panics on a difference.
- `OnInstall` is the migration hook. It runs inside `UpdateImpl` before the
  switch, and `prevVersion` tells it which implementation was active, which
  is also the layout of the data as long as versions activate in sequence.
  Its contract: do nothing when `prevVersion` is its own version (a
  re-install), migrate when it is the version it was written to follow, panic
  otherwise. Keep the migration cheap: at most linear in the number of
  clients, with anything proportional to packets left to lazy conversion on
  access. A migration that is not additive forfeits the rollback.
- A migration rewrites the proxy's store in place. All the state lives in the
  proxy (clients, commitments, receipts, acknowledgements; escrow, vouchers,
  denominations) and the hook reaches it through the `Store` and `Client`
  accessors: it can set and delete entries, and a deletion refunds its storage
  deposit. An implementation realm holds no state of its own, so a superseded
  one leaves only its code deployed and there is nothing to clean up after a
  switch. What a migration cannot do is change the shape of the proxy's own
  types, since their fields are frozen with the proxy: a new shape means new
  objects, through the `/p/` types and the `Ext` fields of the messages.
- `make test`, then the e2e suite with the candidate active (point the
  rehearsal at it, or run the steps below on gnodev).

## 2. Deploy the candidate

One `MsgAddPackage`, from any account that may deploy under the `aib`
namespace, usually the AIB multisig. List the candidate in
`scripts/packages.sh` after the current implementation, so that on a fresh
chain the current one registers first and bootstraps: for the core that is
`impl/v0`; for the transfer app it is `impl/v1` (transfer `impl/v0`
registers nothing; it is the logic `impl/v1` embeds). Then:

```
ONLY=gno.land/r/aib/ibc/core/impl/vN ./scripts/make-deploy-tx.sh   # unsigned tx for the multisig
# or, from a key that owns the namespace on a dev chain:
gnokey maketx addpkg -pkgpath gno.land/r/aib/ibc/core/impl/vN \
  -pkgdir gno.land/r/aib/ibc/core/impl/vN \
  -gas-fee 1000000ugnot -gas-wanted 200000000 -max-deposit 100000000ugnot \
  -broadcast -chainid <chain-id> -remote <rpc> <key>
```

On a chain with `code_submission_policy = inert` (onyx, mainnet) the package
parks until the approvers enable it; `init`, hence the registration, runs at
enablement. Wait for `vm/qpkgmeta_json` to report it `live` (`deploy.sh` does
this polling).

## 3. Check the registration

Registration activates nothing. The candidate must appear as registered and
the active implementation must be unchanged:

```
gnokey query vm/qeval -data 'gno.land/r/aib/ibc/core.RegisteredImplPaths()' -remote <rpc>
gnokey query vm/qeval -data 'gno.land/r/aib/ibc/core.ImplPath()' -remote <rpc>
```

The `admin` page of the realm shows the same.

## 4. Activate it

`UpdateImpl` is a decision of the governance realm `gno.land/r/aib/ibc/ibcgov`
(ADR pr6375 R14): the proxies accept it from that realm only, and the decision
waits 7 days after it is recorded, during which a cancel decision can withdraw
it and a guardian hold defers it. Before the governor yields, the governor
records it with `MsgRun` (the request is a struct, so `MsgCall` cannot build
it):

```gno
package main

import "gno.land/r/aib/ibc/ibcgov"

func main(cur realm) {
	ibcgov.Govern(cross(cur), ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/vN"))
}
```

After the yield, a GovDAO member proposes the same request, members vote and
anyone executes the proposal, which records the decision:

```gno
package main

import (
	"gno.land/r/aib/ibc/ibcgov"
	"gno.land/r/gov/dao"
)

func main(cur realm) {
	pid := dao.MustCreateProposal(cross(cur), ibcgov.NewCoreUpdateImplRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/vN").Proposal())
	println("proposal:", int64(pid))
}
```

```
gnokey maketx run ... <member-key> propose.gno
gnokey maketx call -pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple -args <pid> -args YES ... <member-key>
gnokey maketx call -pkgpath gno.land/r/gov/dao -func ExecuteProposal -args <pid> ... <any-key>
```

Seven days later anyone applies it, with the decision number the ledger
assigned (`gno.land/r/aib/ibc/ibcgov:decisions`):

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/ibcgov -func Execute -args <decision> ... <any-key>
```

The transfer app is the same with `NewTransferUpdateImplRequest`.

The proxy then builds the candidate against its store, runs `OnInstall`,
switches, and emits `impl_updated{old_path,new_path,version}`. The builder
refuses a path that is not registered yet. When the decision executes,
ibcgov first runs the proxy's `CheckUpdateImpl(path)`. It reads the
registered manifest and builds the candidate against a fresh, empty store
(never the live one), then refuses: a path not registered, a manifest that
does not install over the active version, a candidate that builds another
version than its manifest (or, for transfer, answers otherwise whether it
keeps the controls), an install hook that refuses the active implementation
(declared as `CheckInstall(prevPath, prevVersion)`, a pure check the proxy
evaluates), or, for the transfer app, an implementation that does not keep
the route controls once any route exists. Each spends the decision instead
of leaving it pending. Only what the preflight cannot evaluate still rolls
back the whole `Execute` transaction and leaves the decision pending: a
panic in candidate code (the constructor or `OnInstall`), a constructor
whose result depends on the store it is handed, or a hook refusing on a
condition it does not declare through `CheckInstall`.

### When a migration fails

- A version mismatch or a declared hook refusal is caught by the preflight
  and spends the decision. A panic in the constructor or in `OnInstall`
  aborts the whole transaction: the switch does not happen, nothing the hook
  wrote persists, the previous implementation stays active, the candidate
  stays registered and the ibcgov decision stays pending. Executing it again
  later merely retries; declare a hook's conditions in `CheckInstall` so
  they are refused instead.
- A realm path cannot be redeployed, so a fix ships as the next version. Its
  hook is installed over the implementation that is still active, not over
  the failed one: a `v2` written after a failed `v1` carries the migration
  from `v0`, and `prevVersion` tells it so.
- A migration that completes but is wrong cannot be detected by the proxy;
  the smoke test of step 5 is what catches it, and the remedy is the next
  version, or the rollback when the migration was additive.

## 5. Smoke test

- `ImplPath()` and `ImplVersion()` report the candidate; the `admin` page
  agrees.
- One `UpdateClient` by the relayer, one transfer in each direction.

## 6. Rollback

`UpdateImpl` with the previous path, through the same governance decision
(7 days). The old implementation is still registered, so nothing needs
redeploying, and its `OnInstall` runs again; but a registered path is not
enough. Before proposing the rollback, check that it would pass:

```
gnokey query vm/qeval -data 'gno.land/r/aib/ibc/core.CheckUpdateImpl("gno.land/r/aib/ibc/core/impl/v0")' -remote <rpc>
gnokey query vm/qeval -data 'gno.land/r/aib/ibc/apps/transfer.CheckUpdateImpl("gno.land/r/aib/ibc/apps/transfer/impl/vN")' -remote <rpc>
```

An empty string means it would apply; otherwise the reason is the one the
decision would be spent with:

- the previous implementation's manifest must install over the version now
  active (its `over` list; core `impl/v0` declares `nil`, any; core `impl/v1`
  declares `""` and `v0`);
- for the transfer app, once any Ethereum route exists, the implementation
  must keep the route controls (its manifest's `keepsControls`): the
  controls are never rolled back. The rehearsal candidate
  `e2e/gno/rehearsal/transfer-v99` declares it does not keep them, so it can
  be activated, and rolled back from, only before any route is enrolled.
  Transfer `impl/v0` is no rollback target at all: it never registers.

## 7. Ethereum routes on a fresh deployment (transfer impl/v1)

The transfer app is deployed fresh with `impl/v1` as its initial
implementation: it registers first (see `scripts/packages.sh`), serves every
non-Ethereum client as `impl/v0` does, and puts every Ethereum client under
the route controls (ADR 0004). There is no migration from `impl/v0`: an
Ethereum client carries nothing until a decision makes it a route.

0. **Authenticate the client's initial state independently (mandatory).**
   `CreateClient` stores the Ethereum client state and the initial consensus
   state as given, with no bootstrap proof: the light client trusts them
   from then on, and enrolling the client checks only that it is usable
   (Active, not retired, counterparty registered), not that its checkpoint
   is genuine. Before creating it, and again before voting on its
   enrollment, check against sources you trust, independently of whoever
   proposes them: the checkpoint (finalized slot, execution state root and
   timestamp), the current and next sync committee summaries (pubkeys hash,
   aggregate key), the chain parameters (chain id, genesis validators root,
   genesis time and slot, fork schedule, slot, epoch and period lengths,
   sync committee size, minimum participants) and the router configuration
   (the ICS26 router address and its commitment mapping slot). A wrong value
   lets forged headers or proofs through.
1. Create the Ethereum client and register its counterparty (the router's
   client id, eureka's single empty merkle prefix). `CreateClient` needs a
   listed relayer while the whitelist names any; `RegisterCounterparty` must
   be signed by the same origin signer that created the client, and is
   write-once: a registered counterparty is never replaced. Ethereum's public
   relaying covers updates and packets, not these two calls.
2. Enroll it with `NewEnrollRouteRequest(clientID, feeCollector, bridge)`
   (7 days), where `bridge` names the route's Ethereum router, ICS20
   transfer and IBCAdmin ("router ics20 ibcAdmin", protected recipients from
   then on).
3. Seat the guardians and watch keys. All six seats start empty (seats 0–3
   guardians, 4–5 watch keys), and an unseated key cannot flag, so no hold
   or flag protects the route until they are seated: install them with
   `NewSetSeatsRequest("0:g1...,1:g1...")`, at most two guardian seats a
   decision, each addition waiting 7 days (and, under a hold, until day 21
   of it).
4. Once the enrollment has executed, bind the governance channel to the
   route's client with `NewBindGovernanceRequest(clientID)` (7 days): the
   client must still be Active and the route's current client when it
   executes. Every Ethereum-bound decision (`NewEth*Request`) is refused
   until the channel is bound.
5. Enable each denom with `NewSetDenomRequest` (7 days).
6. A client of a route is replaced with `NewReplaceRouteRequest` (an Active
   Ethereum client that is no route's client yet), which closes the route
   until `NewReopenRouteRequest`.
7. A client's verifier is replaced by another verifier version (ADR pr6375
   R16) in two governed steps: first a core implementation that compiles the
   conversion in (`implv1.NewWithConversions`: from version, to version,
   the new verifier package's conversion) is registered under
   `gno.land/r/aib/ibc/core/impl/` and installed with
   `NewCoreUpdateImplRequest` (7 days); then `NewReplaceVerifierRequest(
   clientID, toVersion)` (7 days) converts the client. A conversion the
   active implementation does not declare, a client not Active, a verifier
   exposing no ethereum/v0 state (`Ethereum()`, which the conversion reads),
   or a converted verifier failing its checks spends the decision. The client
   keeps its id and every consensus state it trusted (served read only from
   the retired verifier), its trust generation advances and its route's
   payout meters start empty.
