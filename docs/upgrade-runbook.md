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
  otherwise. Keep the migration bounded: constant work, whatever the number
  of clients, packets, denoms or records. Anything proportional to them is
  converted lazily on access, or by a permissionless continuation that does
  a bounded batch a call (as `transfer.ContinueReopen` does), never in the
  hook: an installation whose work grows with the state could one day
  exceed a transaction's gas and leave its decision pending for good. The
  implementations shipped so far install in constant work (their hooks only
  check `prevVersion`), and a verifier replacement converts in constant work
  (`ethereum.NewFrom`). A migration that is not additive forfeits the
  rollback.
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
   then on). The router must be the one the client reads (its
   `IBCContractAddress`). The route records the client's identity, the chain
   id, genesis validators root, router and commitments slot
   (`ibcgov.RouteIdentity(route)`), and every later replacement client must
   name the same.
3. Seat the guardians and watch keys. All six seats start empty (seats 0–3
   guardians, 4–5 watch keys), and an unseated key cannot flag, so no hold
   or flag protects the route until they are seated: install them with
   `NewSetSeatsRequest("0:g1...,1:g1...")`, at most two guardian seats a
   decision. Every seat change waits 7 days and, under a hold, until day 21
   of it, a vacancy (`"1:"`) included: a vacancy removes the holder the seat
   had when the request was built, and is skipped if the seat changed hands
   since.
4. Once the enrollment has executed, bind the governance channel to the
   route's client with `NewBindGovernanceRequest(clientID)` (7 days): the
   client must still be Active and the route's current client when it
   executes. Every Ethereum-bound decision (`NewEth*Request`) is refused
   until the channel is bound.
5. Enable each denom with `NewSetDenomRequest` (7 days).
6. A client of a route is replaced with `NewReplaceRouteRequest` (an Active
   Ethereum client that is no route's client yet, authenticating the route's
   identity), which closes the route until `NewReopenRouteRequest`; §8 is
   the whole incident drill. While the governance epoch runs over the old
   client, the replacement retires it for transfers only: the epoch moves to
   the new client when IBCAdmin's epoch notice arrives over it (sent when
   Ethereum executes the matching kind 10, or its emergency recovery), and
   the old client is then retired for good. The notice is accepted only
   along a transition ibcgov expects: dispatching the kind 10 records it;
   for an emergency recovery, record `NewExpectRecoveryRequest(oldRouterClient,
   newRouterClient)` (at once) before relaying its notice. A notice that
   arrives before the replacement executes here moves the epoch all the
   same.
7. A client's verifier is replaced by another verifier version (ADR pr6375
   R16) in two governed steps: first a core implementation that compiles the
   conversion in (`implv1.NewWithConversions`: from version, to version,
   the new verifier package's conversion) is registered under
   `gno.land/r/aib/ibc/core/impl/` and installed with
   `NewCoreUpdateImplRequest` (7 days); then `NewReplaceVerifierRequest(
   clientID, toVersion)` (7 days) converts the client. A conversion the
   active implementation does not declare, a Frozen client, a verifier
   exposing no ethereum/v0 state (`Ethereum()`, which the conversion reads),
   or a converted verifier failing its checks spends the decision. The client
   keeps its id and every consensus state it trusted (served read only from
   the retired verifier), its status (Active or Expired) and the slot it
   trusts consensus states from; its trust generation advances and its
   route's payout meters start empty.

   **Deadline.** A client whose updates stop (an unsupported fork, a
   verifier defect) expires about 9.1 days after its latest trusted slot on
   mainnet (ADR 0003). The two steps take 14 days at best, more under a
   guardian hold (a hold defers both until it ends). Prepare ahead: register
   and install the conversion-bearing core implementation before the fork
   it is for, so that only the 7-day `NewReplaceVerifierRequest` remains
   when a client stalls; record it within about two days of the stall and
   the client is converted while still Active. **Missed deadline.** If the
   client expired first, the conversion still applies and keeps it Expired;
   then recover it the ordinary way: authenticate a checkpoint ahead of the
   client independently (as in step 0), create a substitute client from it
   (its verifier converted too if it must be), and record
   `NewRecoverClientRequest(clientID, substituteID)` (7 days). A Frozen
   client is recovered first, then converted.

## 8. Incident drill: replacing a route's client

A suspect or failed client of a route (a forged header accepted, a frozen or
expired client that cannot be recovered in time) is replaced on both chains,
the route's packets of the suspect interval are proven and settled, the
losses resolved, and the route reopened. Every decision below is recorded
by the governor with `ibcgov.Govern` (or, after the yield, a GovDAO proposal
of the same request: §4), and executed by anyone with `ibcgov.Execute(id)`
once due; `ibcgov.Decision(id)` shows its state and note. `R` is the route
key, `OLD` its current gno.land client, `NEW` the replacement, `ROLD` and
`RNEW` the router's client ids on Ethereum, `INC` the incident name (1 to 32
characters of `a-z`, `0-9`, `-`).

1. **Contain.** Guardians and watch keys flag at once, from their seat keys:

   ```
   gnokey maketx call -pkgpath gno.land/r/aib/ibc/ibcgov -func SetFlag -args R -args payouts -args "<suspect packet keys, or empty>" ... <seat-key>
   ```

   per function (`sends`, `credits`, `payouts`, `refunds`). Two guardian
   seats flagging make a hold: every queued decision is deferred, unpauses
   are spent. A guardian's `payouts` flag naming packets makes their void
   immediate (`NewVoidRequest(R, keys, forged, INC)`). Check:
   `ibcgov.Held()`, `ibcgov.Flags(R)`.
2. **Cancel** any pending decision the incident makes unsafe (an upgrade, a
   denom loosening, a sweep): `NewCancelRequest(id)` applies at once, hold
   or not. Ethereum-bound decisions are cancelled on Ethereum by kind 1
   (`NewEthCancelRequest`).
3. **Choose `suspectFrom`.** It is the gno.land height from which
   acknowledgements and timeouts processed through `OLD` are suspect: the
   height of `OLD`'s first update after its last consensus state you have
   authenticated independently (step 0 of §7). When in doubt, take an
   earlier height: every record processed from it on must be settled, and
   one too many costs a proof, one too few a forged refund kept. `0` takes
   every record; the controls raise it to the previous replacement's height.
   Ethereum's kind 10 takes its own `suspectFrom`, an Ethereum block.
4. **Prepare `NEW`.** Authenticate a
   checkpoint independently (§7 step 0), create `NEW` from it with the
   route's identity (`ibcgov.RouteIdentity(R)`: the same chain id, genesis
   validators root, router and commitments slot; any other is refused), and
   register its counterparty `RNEW` (a custom id kind 6 adds on Ethereum).
5. **Lift the hold, keep the containment.** A hold defers the replacement
   too. The guardians clear their flags (`ClearFlag(R, fn)`), and the hold
   ends 24 hours after fewer than two guardian seats flag, while the watch
   keys keep their `sends`, `credits` and `payouts` flags: those pause the
   functions without making a hold. Keep a `refunds` flag until the
   replacement has executed: until then a queued refund could still be paid
   (`ClaimRefunds`); once the route is closed nothing is, and the flag
   would only defer the settlements that pay genuine refunds (step 9).
6. **Replace, on both chains.** Record `NewReplaceRouteRequest(R, NEW,
   suspectFrom)` (7 days) and Ethereum's kind 10,
   `NewEthRouteReplacementRequest(ROLD, RNEW, suspectFromBlock)` (sent at
   once; IBCAdmin applies its own delay). The gno.land replacement closes
   `R` (voucher returns over `NEW` still go: exit only) and retires `OLD`
   for transfers; while the governance epoch runs over `OLD` it stays there,
   so the kind 10 and every decision in flight can still be re-sent
   (`Redispatch`). When IBCAdmin executes kind 10 (or Ethereum's emergency
   recovery, if `OLD` cannot carry it; then first record
   `NewExpectRecoveryRequest(ROLD, RNEW)` here) it sends the epoch notice
   over `NEW`;
   relay it (`RecvPacket` on `NEW`, port `gov`). Check: `ibcgov.Epoch()` one
   higher, `ibcgov.EpochClient() == NEW`, `core.IsClientRetired(OLD)`. A
   notice refused with an error acknowledgement (sent before the
   replacement was recorded here) is sent again by IBCAdmin.
7. **Enumerate the records to settle.** Every send record of `OLD` that is
   open (outcome `""`, its commitment outstanding, or payment `queued`), and
   every one processed at or after `suspectFrom` (`processed_height`) whose
   `settlement` is 0, read from the pages of
   `Render("routes/R/sends?from=<next>")` (keys `OLD/…`). Their count is
   `SuspectUnsettled(R, OLD)` on the controls reader
   (`transfer.ExtView("controls")`) plus the open ones. A record carries the
   full packet, so a record whose commitment the core already deleted (an
   acknowledgement or a timeout processed it) is proven and settled the same
   way. Receives of `OLD` whose claims or sweep entries paid out and that
   the router never sent are the forged receives (claims and sweeps pages).
8. **Prove each outcome** through `NEW` (the route's current client), at a
   height `H = (0, slot)` of a consensus state `NEW` holds, with
   `transfer.ProveOutcome(packet, H, receiptProof, ackProof)` from a
   `MsgRun` (the packet is the record's, the proofs `ethereum.MembershipProof`
   values of the router's storage at `H`, from `eth_getProof` of the
   router's commitments entries `keccak256(keccak256(path) ‖ commitmentSlot)`
   for the packet's receipt path and acknowledgement path, both under its
   destination client on the router, `ROLD`). No receipt is refundable
   only at a height whose time is at or past the packet's timeout; the
   packet's receipt with eureka's success acknowledgement is delivered, with
   the universal error acknowledgement refundable; another packet's receipt
   is a collision (refundable). Check: the record's `proven`, `proven_by`,
   `proven_gen`. An outcome is void once `NEW` is recovered, frozen,
   upgraded or migrated (`core.ClientTrustGeneration(NEW)` no longer the
   record's `proven_gen`): prove it again.
9. **Settle**, at most 64 items a decision, each record once:
   `NewSettleRequest(R, OLD, "seq:action:amount,…", INC)` (7 days):
   - proven refundable or collision: `1` with the amount minus `refunded`
     (`0` for one refunded in full, which only settles it); a minted refund
     the supply cannot hold now is parked, owed and reserved, and paid by
     `ClaimRefunds` after the reopening;
   - proven delivered, a queued refund none of which was paid: `2`, amount
     `0`;
   - proven delivered, no refund paid: `3`, amount `0`;
   - proven delivered and refunded (a forged refund): `4`, amount
     `refunded`, booked as a loss;
   - a forged receive (inbound sequence): `5`, amount what it paid out,
     booked as a loss; its claim's remainder is dropped.

   A settlement paying refunds is deferred under a `refunds` flag (step 5).
   Ethereum's records are settled by kind 12 (`NewEthSettleRequest`, at most
   8 items). Check: `settlement` set on every record of step 7, and
   `SuspectUnsettled(R, OLD)` 0.
10. **Resolve the losses**, per denom and incident (`Render("routes/R/losses")`,
    `Totals(R, denom)`): recapitalize an `unescrow` denom
    (`NewRecapitalizeRequest(R, denom, amount, INC)`, then anyone pays it
    with `transfer.Recapitalize(R, id)`), reduce open or withheld claims or
    owed sweep entries (`NewReduceRequest(R, key, amount, INC)`), or accept
    a deficit (`NewAcceptDeficitRequest(R, denom, amount, INC)`); whatever
    stays unresolved, the reopening accepts. Check: `Unresolved(R)`.
11. **Reopen.** `NewReopenRouteRequest(R)` (7 days) is refused while a
    record of step 7 is unsettled. When it applies, it accepts the remaining
    losses and revokes unpaid recapitalizations in batches; if its note says
    so, call `transfer.ContinueReopen(R)` until it returns true. Ethereum
    reopens by kind 13 (`NewEthReopenRequest(RNEW)`). Check:
    `Closed(R)` false.
12. **Clear the flags.** The watch keys and guardians clear their own flags
    (`ClearFlag`), or `NewUnpauseRouteRequest(R, "sends,credits,payouts,refunds")`
    clears every seat's at once (spent while a hold stands). Clearing
    `payouts` starts a new payouts epoch: the meters refill from empty. Then
    pay what waited: `transfer.ClaimRefunds(NEW, denom, n)` and
    `transfer.Claim(NEW, denom, n)`. Done when `ibcgov.Flags(R)` is empty,
    `ibcgov.Held()` false, `Closed(R)` and `LossClosed(R)` false, and every
    denom's `queued_refunds` drained.
