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
  `gno.land/r/aib/ibc/apps/transfer/impl/vN`. The `v<N>` suffix is a
  convention: registration checks only that the path is under the proxy's
  `/impl/` namespace, and ibcgov's update builders that it starts with
  `/impl/v`; neither parses a number. It
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
  Which predecessors a candidate installs over is declared by its manifest
  (`over`, enforced by the governed preflight, `CheckUpdateImpl`, only: the
  installation re-checks the built version and controls against the
  manifest, not `over`; a hook that needs its own predecessor check makes
  it in `OnInstall`) and, where it
  needs more, by its hook (`CheckInstall`/`OnInstall`). The shipped hooks:
  core `impl/v0`'s is empty (its manifest accepts any predecessor); core
  `impl/v1`'s accepts `""`, `v0` and itself and refuses any other; transfer
  `impl/v1`'s accepts any predecessor and initializes the route controls'
  extension, idempotently (`InitExt`, a no-op once it exists). A new hook
  should do nothing on a re-install, migrate from the version it follows,
  and refuse the rest. Keep the migration bounded: constant work, whatever the number
  of clients, packets, denoms or records. Anything proportional to them is
  converted lazily on access, or by a permissionless continuation that does
  a bounded batch a call (as `transfer.ContinueReopen` does), never in the
  hook: an installation whose work grows with the state could one day
  exceed a transaction's gas and leave its decision pending for good. The
  implementations shipped so far install in constant work, and a verifier
  replacement copies no consensus-state history (`ethereum.NewFrom`): it
  costs O(log previous verifier stores), inserting the retired store into
  the persistent history index and any head it rewrote at or below the
  index's top into the persistent override tree; reads of the retired
  history take O(log replacements). A migration that is not additive forfeits the
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
   along a transition ibcgov expects, and over the local client it names
   only: dispatching the kind 10
   (`NewEthRouteReplacementRequest(old, new, suspectFrom, localClient)`)
   records it as a decision of its own, applied after 7 days (anyone
   executes it; a hold defers it); for an emergency recovery, record
   `NewExpectRecoveryRequest(oldRouterClient, newRouterClient, localClient)`
   (7 days, deferred by a hold) before relaying its notice. A notice more
   than one epoch on is recorded as proven when relayed; then call
   `ApplyEpochNotice(epoch, localClient, "router1/local1,...,routerK/localK")`
   with its path of expected transitions from the current epoch client
   (the client that proved it must still be Active, at the same trust
   generation). A notice may be any number of epochs on, up to the expected
   graph's 64 transitions, as long as its whole path is recorded here: no
   cap on Ethereum's side is assumed. A transition Ethereum cancelled or
   never executed is removed at once with
   `NewRemoveExpectationRequest(oldRouterClient, newRouterClient,
   localClient)`, freeing its place; it is refused only while a notice
   proven over a client the transition leads to could still be applied (its
   epoch past the current, its client Active, not retired, at the same
   generation). Once that client is frozen, expires, is recovered or has
   its verifier replaced, or the epoch reaches the notice's, the removal
   goes through. When Ethereum's epoch is more than 64 ahead, catch up in
   prefixes: have IBCAdmin resend the notice of an intermediate epoch within
   the recorded graph (any recorded epoch's notice can be resent, even
   after it was acknowledged, over that epoch's own router client), relay
   and apply it; the switch frees the transitions behind it, so record the
   next expectations (7 days each) and repeat. If the gno local client of
   an intermediate transition failed, recover it in place
   (`NewRecoverClientRequest`, 7 days; it keeps its id, which Ethereum's
   packets are addressed to) and relay the resent notice through it; if
   Ethereum's recovery created a new router client instead, record that
   transition with a fresh local client (`NewExpectRecoveryRequest`).
   Resending is harmless: the current epoch's notice is answered as a
   duplicate (status 3), one of a transition not taken or an epoch passed
   gets an error acknowledgement, and one over a client retired for
   governance is refused by the core; none changes anything.
   Outbound decisions are re-sent the same way: `ibcgov.Redispatch(e, seq)`
   sends a current-epoch decision again, identical bytes in a fresh packet,
   whenever none of its packets is in flight, after any answer but a
   conflict. Use it when a later seq waits on Ethereum behind one gno shows
   as acknowledged (a success acknowledgement a compromised Ethereum-side
   verifier forged): IBCAdmin answers a seq it already holds with a
   duplicate, which changes nothing. A decision answered with a conflict
   (status 4, no redispatch) is not re-sent freely. If a later seq waits
   behind it, check on Ethereum whether the conflict was real: read
   `IBCAdmin.decision(e, seq)` (no decision stored, or one whose hash is
   `keccak256` of `ibcgov.DispatchBody(e, seq)`) and look for a
   `Conflict(e, seq, …)` event and a raised `conflictBlock()`. If IBCAdmin
   holds no decision or these very bytes and emitted no conflict, the
   acknowledgement was fabricated: decide
   `ibcgov.NewRetransmitRequest(e, seq)` (applies at once), then anyone
   calls `ibcgov.Redispatch(e, seq)` once; a further re-send needs a new
   decision. A real conflict (different bytes stored) is never re-sent.

   Removing an expectation (`NewRemoveExpectationRequest`), or cancelling
   one still pending, leaves a tombstone that keeps its local client, and
   those of the transitions beyond it, from being retired for governance
   until an epoch switch supersedes it (`ibcgov.Tombstones()` counts them),
   so the transition can be expected again and its notice still arrives
   over that client. Live transitions and tombstones share one budget of
   64; a removal, a cancellation or approving a tombstoned transition again
   never needs room, a brand-new transition does.

   **All capacity exhausted** (a router client's 4 successors live, the
   joint budget of 64 full, Ethereum's executed transition among the
   tombstones or not recorded at all):
   1. Find the transition Ethereum executed (IBCAdmin's `epoch()` and its
      notices) and whether gno holds it as a tombstone (the `GovTombstone`
      event of its removal or release names it).
   2. Free a successor place of its old router client: remove a losing
      active expectation (`NewRemoveExpectationRequest`, at once; it
      becomes a tombstone, no room needed) or cancel a losing pending one
      (`NewCancelRequest`).
   3. If the executed transition is tombstoned, approve it again
      (`NewExpectRecoveryRequest` with the same router clients and local
      client, 7 days): it moves back into the graph, no room needed.
   4. If it is brand new, free a place in the joint budget first: purge a
      junk tombstone (`NewPurgeTombstoneRequest`, 7 days; refused while a
      recorded notice needs it), then record the expectation (7 days).
   5. Relay the notice afresh (IBCAdmin resends it in a fresh packet) once
      the expectation is active; the switch clears the tombstones it
      supersedes.

   Residuals (ADR 0004 known limits): a forged notice applied by a
   compromised approved local client, or a local client kept Active by
   forged updates at every prefix endpoint, cannot be undone inside ibcgov.
   A forged switch costs nothing when it names the epoch and client a kind
   10 Ethereum already holds will establish (its genuine notice is then a
   duplicate). Otherwise the only repair is Ethereum's emergency recovery
   (if enabled): record its expectation from the router counterparty of
   gno's current epoch client (`ibcgov.EpochClient()`), over a fresh healthy
   local client, so its notice switches from there; its epoch must be above
   gno's, so a gno pushed ahead needs as many recoveries as pass it, each
   step's expectation recorded. A poisoned client is recovered in place
   only once misbehaviour freezes it or it expires. Core and transfer take
   loosening governance only from ibcgov's fixed path, so no fresh ibcgov
   can take over; when Ethereum can reach the adopted epoch and client by
   neither, Ethereum-bound governance is lost, while gno-side governance
   goes on. If it is not, the notice must be proven afresh: relaying
   the original packet again only returns `RESPONSE_NOOP` (its receipt
   exists); IBCAdmin sends the identical notice bytes in a fresh packet
   (`resendEpochNotice(epoch)`, a new transport sequence), and that packet
   is relayed. After switches, anyone calls
   `ibcgov.PruneGovRetirements(64)` to retire for good the replaced clients
   no longer reachable on the expected graph; the count
   (`AwaitingGovRetirement()`) need not reach 0: clients still reachable
   are kept, and a later switch or removal makes them eligible, so call it
   again then. The local client is the new gno
   client tracking the new router client, Active, its counterparty set. A notice that
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
   earliest verification operation (an update, or a membership or absence
   proof checked) that may have been compromised, considering verifier
   defects and the implementation versions affected. The default is `0`
   (every record; the controls raise it to the previous replacement's
   height): an authenticated consensus root proves that root genuine, not
   that every proof checked against it was verified correctly. Only when the
   compromise is established to be header-only (forged updates, the verifier
   sound) may it start at the height of `OLD`'s first update after its last
   consensus state authenticated independently (step 0 of §7). One record
   too many costs a proof; one too few keeps a forged refund.
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
   `NewEthRouteReplacementRequest(ROLD, RNEW, suspectFromBlock, NEW)` (sent at
   once; IBCAdmin applies its own delay). The gno.land replacement closes
   `R` (voucher returns over `NEW` still go: exit only) and retires `OLD`
   for transfers; while the governance epoch runs over `OLD` it stays there,
   so the kind 10 and every decision in flight can still be re-sent
   (`Redispatch`). When IBCAdmin executes kind 10 (or Ethereum's emergency
   recovery, if `OLD` cannot carry it; then first record
   `NewExpectRecoveryRequest(ROLD, RNEW, NEW)` here, 7 days, within
   Ethereum's 30-day recovery delay) it sends the epoch notice
   over `NEW`;
   relay it (`RecvPacket` on `NEW`, port `gov`). The notice is accepted only
   once its transition's expectation is active: the kind 10's dispatch
   records it as a separate "expect transition" decision; execute it
   (`ibcgov.Execute(id)`, 7 days after the dispatch, deferred by a hold)
   before relaying; the gno.land route replacement need not have executed.
   Check: `ibcgov.Epoch()` one higher, `ibcgov.EpochClient() == NEW`,
   `core.IsClientRetired(OLD)`. A notice refused with an error
   acknowledgement (sent before its expectation applied) is sent again by
   IBCAdmin in a fresh packet; relay that one.
   The replacement reserves the refunds the retired client's records may
   owe in its first batch (64 steps, plus possibly one final move past a
   client whose records it has just finished). The transfer app's `route_gov` event
   for the replacement says in its `note` attribute "prepare the rest with
   transfer.PrepareReplacement" when more remain (ibcgov's decision note
   does not carry it): then call `transfer.PrepareReplacement(R, 64)` until
   it returns true; a settlement refused as "not prepared" says the same. No
   settlement, sweep payment, credit by vote or reopening applies before.
   The replacement moves the flags standing under `NEW` onto `R`, merging
   one with the route's own flag of the same seat and function: the route's
   named packets come first and the merged flag keeps at most 64, so names
   beyond that are dropped silently and no longer let a void execute at
   once. Guardians read `ibcgov.Flags(R)` after the replacement and
   re-assert (`SetFlag`) any suspect packet name that was dropped.

   **A repeated replacement** (`NEW` failed, or must be replaced, before the
   reconciliation of an earlier retired client finished) runs this step
   again from `NEW` to a fresh client (`NEW2`), and then runs steps 7 to 10
   for every retired client that still blocks the reopening, not only the
   last one replaced:
   - list them with `ReopenBlockers(R)` on the controls reader
     (`transfer.ExtView("controls")`): every retired client with a record
     open or processed in its suspect interval and not settled, whatever
     the number of replacements; the route's `replaced` list
     (`Render("routes/R")`) names every retired client, in order;
   - each keeps its own suspect height, recorded when it was retired
     (`SuspectFrom(R, client)`, raised to at least the height it became the
     route's client): enumerate its records against that height (step 7,
     keys `client/…`), never against the latest replacement's;
   - each keeps its own incident: settle and book its losses under the
     incident name used for its replacement (`INC` of that drill), so its
     accounting stays apart;
   - prove its unfinished records again through the route's current client
     (`NEW2`): an outcome proven through a verifier since retired, frozen or
     recovered is void (step 8);
   - settle them per originating client, `NewSettleRequest(R, client, …,
     its INC)` (step 9), the client being the one the record was sent over.
7. **Enumerate the records to settle.** Every send record of `OLD` that is
   open (outcome `""`, its commitment outstanding, or payment `queued`), and
   every one processed at or after `suspectFrom` (`processed_height`) whose
   `settlement` is 0, read from the pages of
   `Render("routes/R/sends?from=<next>")` (keys `OLD/…`): the union of the
   two sets by packet key, records already settled (`settlement` not 0)
   excluded. `SuspectUnsettled(R, OLD)` on the controls reader
   (`transfer.ExtView("controls")`) counts the second set, which may hold
   queued refunds of the first: do not add the two counts. A record carries the
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
     (`0` for one refunded in full, which only settles it); a refund the
     supply (minted) or the free escrow (escrowed) cannot pay now is parked,
     owed and reserved, never refusing the settlement, and paid by
     `ClaimRefunds` after the reopening, as the supply's headroom or the
     escrow allows (an escrow a forged receive drained: recapitalize it, step
     10, or accept the deficit and reopen, the refund then waiting for the
     escrow to be whole);
   - proven delivered, a queued refund none of which was paid: `2`, amount
     `0`;
   - proven delivered, no refund paid: `3`, amount `0`;
   - proven delivered and refunded (a forged refund): `4`, amount
     `refunded`, booked as a loss;
   - a forged receive (inbound sequence): `5`, amount what it paid out,
     booked as a loss; its claim's remainder is dropped.

   A settlement paying refunds is deferred under a `refunds` flag (step 5).
   A settlement is final once it applies: before then a hold defers it, and
   `NEW` expiring (not Active) or taking a new trust generation (a recovery,
   freeze, upgrade or migration) voids its proofs, but a compromise of
   `NEW` found afterwards does not reopen it, and no governed path on
   gno.land pays a refund it denied. Hold the decision (step 5) while `NEW`
   is in doubt.
   Ethereum's records are settled by kind 12 (`NewEthSettleRequest`, at most
   8 items). Check: `settlement` set on every record of step 7, and
   `SuspectUnsettled(R, OLD)` 0.
10. **Resolve the losses**, per denom and incident (`Render("routes/R/losses")`,
    `Totals(R, denom)`): recapitalize an `unescrow` denom
    (`NewRecapitalizeRequest(R, denom, amount, INC)`, then anyone pays it
    with `transfer.Recapitalize(R, authorizationID)`: the authorization id
    is the route's own numbering, not the ibcgov decision number; read it
    from the transfer app's `route_gov` event of the executed decision
    (`op` `recapitalize`, `route` `R`, its `note` the id), check it with
    `Recap(R, authorizationID)` on the controls reader (denom, amount,
    incident, not paid or revoked), and pass that id to the payment or to a
    revocation (`NewRevokeRecapRequest(R, authorizationID)`)), reduce open or withheld claims or
    owed sweep entries (`NewReduceRequest(R, key, amount, INC)`), or accept
    a deficit (`NewAcceptDeficitRequest(R, denom, amount, INC)`); whatever
    stays unresolved, the reopening accepts. Check: `Unresolved(R)`.
11. **Reopen.** First check the whole route: `ReopenBlockers(R)` on the
    controls reader must be empty (after a repeated replacement it lists
    every retired client still unfinished; `SuspectUnsettled(R, client)`
    and `OpenSends(R, client)` say what each still holds).
    `NewReopenRouteRequest(R)` (7 days) is refused while any retired
    client's record of step 7 is unsettled. When it applies, it accepts the remaining
    losses and revokes unpaid recapitalizations in batches; when the transfer
    app's `route_gov` event says in its `note` "continue with
    transfer.ContinueReopen" (ibcgov's decision note does not carry it),
    call `transfer.ContinueReopen(R)` until it returns true. Ethereum
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
