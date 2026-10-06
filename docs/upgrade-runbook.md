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
- `OnInstall` runs inside `UpdateImpl` before the switch and again on every
  re-install and rollback: keep it idempotent, schema-aware and cheap. A
  migration that is not additive forfeits the rollback.
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

## 5. Smoke test

- `ImplPath()` and `ImplVersion()` report the candidate; the `admin` page
  agrees.
- One `UpdateClient` by the relayer, one transfer in each direction.

## 6. Rollback

`UpdateImpl` with the previous path, through the same authority. The old
implementation is still registered, so nothing needs redeploying; its
`OnInstall` runs again.
