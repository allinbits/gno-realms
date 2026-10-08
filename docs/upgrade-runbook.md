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
`scripts/packages.sh` after the current implementation (a fresh chain then
deploys both, and the first registered, `v0`, bootstraps), then:

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

`UpdateImpl` is reserved to the realm's authority: the AIB multisig and the
GovDAO proxy.

Through GovDAO, a member submits the proposal with `MsgRun` (the request is a
struct, so `MsgCall` cannot build it), members vote, anyone executes:

```gno
package main

import (
	"gno.land/r/aib/ibc/core"
	"gno.land/r/gov/dao"
)

func main(cur realm) {
	pid := dao.MustCreateProposal(cross(cur), core.NewUpdateImplProposalRequest(cross(cur), "gno.land/r/aib/ibc/core/impl/vN"))
	println("proposal:", int64(pid))
}
```

```
gnokey maketx run ... <member-key> propose.gno
gnokey maketx call -pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple -args <pid> -args YES ... <member-key>
gnokey maketx call -pkgpath gno.land/r/gov/dao -func ExecuteProposal -args <pid> ... <any-key>
```

Through the multisig, one `MsgCall`:

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/core -func UpdateImpl \
  -args gno.land/r/aib/ibc/core/impl/vN -broadcast=false ... <multisig-address>
```

then the usual multisign and broadcast.

Either way the proxy builds the candidate against its store, runs
`OnInstall`, switches, and emits `impl_updated{old_path,new_path,version}`.
If the proposal is executed before the candidate is live, the proxy panics,
the execution transaction aborts and the proposal stays executable: run step
3 again later and execute again.

### When a migration fails

- A panic in `OnInstall` aborts the whole transaction: the switch does not
  happen, nothing the hook wrote persists, the previous implementation stays
  active and the candidate stays registered. Activating it again later
  merely retries.
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

`UpdateImpl` with the previous path, through the same authority. The old
implementation is still registered, so nothing needs redeploying; its
`OnInstall` runs again.
