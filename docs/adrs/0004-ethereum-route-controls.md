# ADR 0004: Ethereum route controls, the ibcgov governance realm and core changes

- Status: Proposed
- Date: 2026-10-16
- Implements: the gno.land side of gno ADR
  [`pr6375_ibc_ethereum`](https://github.com/clockworkgr/gno/blob/feat/secp256k1-validators-ibc/gno.land/adr/pr6375_ibc_ethereum.md)
  (rows R8–R14, R16–R19 of §4.3; §5.4; §6.1–§6.3, §6.6–§6.8, §6.10–§6.12;
  §7.1, §7.3–§7.9, §7.11 records, §7.12 gno side, §7.13; §9). R15 (18-decimal
  tokens), the relayers and the monitors are out of scope.
- Supersedes: the authority sections of ADR 0001 and ADR 0002 (no deployer
  member; loosening powers move to `gno.land/r/aib/ibc/ibcgov`).
- Depends on: ADR 0001, ADR 0002, ADR 0003.

## Context

The IBC v2 path between gno.land and Ethereum works end to end; the safety and
governance controls of ADR pr6375 §7, ported from gnolang/bridges (Hyperlane
design), were designed but not built. They must:

- bound what a light-client forgery can take (meters and a claim queue on
  gno.land, a refund meter, voids and a loss ledger);
- let guardians pause per function and hold governance, never trapping exits;
- put every loosening change behind a 7-day decision, decided by a governor
  until a one-way yield to GovDAO, and govern the Ethereum side over IBC;
- survive the loss or poisoning of a client (route replacement) and let a
  reconciliation authenticate every packet (send records, identifying
  receipts).

The core and transfer proxies are not deployed yet, so their surfaces can
still change; once deployed they freeze (ADR 0001, 0002). The deployment is
fresh: no network has them live with state to keep, so the transfer proxy
starts with impl/v1 and there is no migration from impl/v0 (round 10).

## Decision

### Components

| Component | Path | Role |
|---|---|---|
| Decision ledger | `p/aib/decisions/v0` | Vendored from gnolang/bridges `solana/realm/p/decisions/v0` (ADR pr6375 open question 8: vendor under our namespace). Adds `UnpauseDelay`, `Decision.Copy`, `Ledger.Find`. |
| ABI encoder | `p/aib/encoding/abi/v0` | `abi.encode` of words, string, bytes, tuples, `T[]`; checked against viem vectors and the ICS20 encoder. |
| Ethereum addresses | `p/aib/encoding/ethaddr/v0` | Ported from bridges `hlmailbox/ethaddr.gno`: EIP-55 parsing, zero and reserved (≤ 0xffff) predicates. |
| Route controls | `p/aib/ibc/ics20/controls/v0` | The state machine of §7.1/§7.8/§7.9/§7.12/§7.13, allocated in the transfer proxy (meters, claims, sweeps, send records, refund meter, voids, losses, route keys). Algorithms ported from bridges `hlroute` and `hlgnot/installments.gno`. |
| Fork-schedule migration | `p/aib/ibc/lightclient/ethereum/v0` `migrate.gno` | `EthLightClient.MigrateForkParameters`, wire codec of `ForkParameters`. |
| Core proxy | `r/aib/ibc/core` | Authority split, public relaying for Ethereum clients, identifying receipts, `RetireClient`, `MigrateClient`, read accessors. |
| Core impl v1 | `r/aib/ibc/core/impl/v1` | v0's lifecycle + `core.ClientMigrator` (`ethereum-fork-schedule`). |
| Transfer proxy | `r/aib/ibc/apps/transfer` | Authority split, `Claim`, `ClaimRefunds`, `Recapitalize`, `GovApply`, extension store, `EmitRoute`. |
| Transfer impl v1 | `r/aib/ibc/apps/transfer/impl/v1` | v0 for non-Ethereum clients; the route controls for Ethereum clients. |
| Governance | `r/aib/ibc/ibcgov` | Ledger, governor/yield, builders, guardians (seats, flags, holds), gov port sender. |
| Markdown-inert JSON | `p/aib/jsonmd/v0` | `Quote` and `Inert`: JSON whose string literals carry every Markdown- or HTML-active character as a `\u` escape, so a Render page shows user strings as inert text and a JSON parser reads the same values. |
| Test fixture | `p/aib/ibc/lightclient/ethereum/testing/v0` | An Ethereum client usable in filetests, and `Router`: genuine Merkle-Patricia proofs of router commitments, so filetests relay real packets through the core. |

### Storage

- **Core proxy**: unchanged layout plus `coreStore.retired` (client → true)
  and, per client, `trustGen`: its trust generation, which the core itself
  bumps after every recovery, freeze (an update that leaves the client
  Frozen), upgrade, migration and substitution of the verifier
  (`core.ClientTrustGeneration`). A counterparty's merkle prefix is stored
  as a deep copy, handed out as copies, and an Ethereum client's must be
  eureka's canonical single empty element. The Ethereum light client keeps
  `TrustedFromSlot`, the slot a recovery copied: consensus states below it
  serve no proof, timestamp or update again.
  A receipt's value is now `types.CommitPacketReceipt(packet)` =
  `sha256(0x03 ‖ uint64be(sequence) ‖ sha256(sourceClient) ‖ CommitPacket(packet))`
  at the ICS24 receipt path (R19); counterparties only prove absence.
- **Transfer proxy**: unchanged layout plus `ext` (key → value): impl/v1 stores
  one `*controls.Registry` under `"controls"` through `InitExt`, called from
  its `OnInstall` with the `/p/` constructor `controls.NewRegistryAny`, so it
  is allocated in the proxy's storage and survives implementation switches.
  `ExtView` hands out its `controls.Reader` (values only, no mutator).
  - `Registry`: routes by route key; aliases current client → route key;
    retired client → route key.
  - `Route`: current client, replaced clients, activation height, closed
    flag, fee collector, refused recipients, protected recipients (the
    router, ICS20 transfer and IBCAdmin its enrolment named, and every
    voucher token a denom names: never unrefused, kept through
    replacements), denoms, claims and sweep entries
    (by packet key `client/seq`), send records (by packet key) and the count
    of open records per client, losses and per-incident loss totals,
    recapitalization authorizations.
  - `Denom`: configuration (kind, cap floor or mint cap, supply cap, fee and
    floor, send max/min, refund cap, the gno-native denom's Ethereum token),
    bridge meter, per-recipient queues and meters, refund meter and queue,
    totals (credited, owed, withheld, swept, paid, fees, outstanding vouchers,
    returning vouchers, sent, refunded, queued refunds, lost, recapitalized,
    reduced, accepted).
  - `SendRecord`: the packet, its commitment, metadata, outcome, payment
    state, refunded amount, remaining supply reservation (minted sends,
    released or consumed once), reconciliation settlement (once), and a proven outcome with its verifier and the verifier's trust
    generation at the proof.
  - Per client, the processed send records not settled by reconciliation,
    ordered by processing height (an `avl.Node`, so the records processed at
    or after a replacement's suspect height are counted in logarithmic work);
    per retired client, its suspect height; the retired clients that still
    block a reopening (`blocking`), and a count of the denoms with an
    unresolved loss (`unresolvedDenoms`).
  - Per denom, the queued refunds in order and indexed by packet key
    (`refundIdx`).
  - Escrow stays in the proxy's existing per-key accounting, keyed by the
    route key (= the first client id, so pre-existing escrow carries over).
- **ibcgov**: `ledger`, `yielded`, `seats[6]`, `flags` (route|fn|seat),
  `routes` (route key → payouts epoch, the route's identity recorded at
  enrolment), `holdSince`/`belowSince`, `epoch`,
  `epochs` (epoch → client, last seq), `expected` (the expected
  governance transitions, kept apart from the transfer aliases, in router
  client ids: an old client → up to 4 expected successors), `awaitingGov`
  (gno clients retired for transfers only while on an expected path), `dispatches` ((epoch, seq) → bytes,
  status, transport sequence), `pendingAuth` (one-time, never persisted
  between transactions in practice: set and consumed in the same call).

### Authorities (R14)

| Operation | Who |
|---|---|
| `core.Pause`, `PauseApp`, `RejectApp`; `transfer.BlockAddress` | authority members: GovDAO proxy (proposals in the realms) and ibcgov. No deployer. |
| `core.Unpause`, `UnpauseApp`, `ApproveApp`, `AddRelayer`, `RemoveRelayer`, `RecoverClient`, `UpdateImpl`, `MigrateClient`, `RetireClient`, membership; `transfer.UnblockAddress`, `UpdateImpl`, membership, `GovApply` | ibcgov only (`cur.Previous().PkgPath() == IBCGovPath`) |
| ibcgov decisions | the governor (`Govern`, MsgRun) until `Yield()`, then GovDAO proposals only (`req.Proposal()`) |
| ibcgov `Execute`, `Redispatch`; transfer `Claim`, `ClaimRefunds`, `ProveOutcome`, `ContinueReopen`, `Recapitalize` | anyone |
| ibcgov `SetFlag`, `ClearFlag` | the seat's key, on a route ibcgov enrolled or any Ethereum client (one about to become a route's); a client of a route, current or retired, names its route (flags are kept under the route key) |
| `UpdateClient`, `RecvPacket`, `Acknowledgement`, `Timeout` on an Ethereum client | anyone (R17); other clients keep the relayer whitelist |

Candidate implementation code reaches the live store only through an
authorized installation: the bootstrap registration, or a governed `UpdateImpl` after
its 7-day delay. Each implementation registers, beside its constructor, a
manifest of plain values (`RegisterImpl(cur, ctor, version,
over[, keepsControls])`: the version it reports, the versions it installs
over, and for transfer whether it keeps the route controls).
`transfer.KeepsControls` reads the manifest only. The preflight, unlike
it, runs candidate code:
`CheckUpdateImpl` (core and transfer) reads the manifest, then builds the
candidate against a fresh, empty store, never the live one (core's
`newStore()`, transfer's `sandboxStore`, which holds nothing and refuses
every write), and checks the built version (and, for transfer, whether it
keeps the controls) against the manifest and, through `InstallChecker`, the
install hook's condition, a pure function of the active implementation's
path and version the proxy passes (Codex round 29, z1m). Nothing is handed
the live store or a stored object before approval; the installation checks
the built implementation against its manifest again. Paths by which code
could reach a store or a mutable stored object, swept (Codex rounds 17,
29): the preflights above (were building the candidate with the live
store; now against an empty one); the installation itself (authorized only); the active
implementation's dispatch and `Render` (the approved implementation, by
design); the stores' accessors (unexported `store` values handed only to an
installed implementation; transfer's `Denoms`/`Vouchers` are read-only
views, `ExtView` a read-only reader); core's exported functions (they
return values: heights, statuses, timestamps, bytes, never a light client
or a client record); `CheckRecoverClient` and `CheckMigrateClient` (run
the active implementation's and the light client's own checks, no
mutation); ibcgov (keeps its state unexported, returns values). Light
clients expose exported mutators (`Initialize`, `UpdateState`,
`UpdateStateOnMisbehaviour`, `RecoverClient`, `MigrateForkParameters`,
`VerifyUpgradeAndUpdateState`); a stored one is reachable only through
core's store, so only through the installed implementation's guarded
paths, and `Initialize` runs once on both the Ethereum and the Tendermint
client, so a stored client's trusted state is never replaced through it.
A light client keeps no slice its caller still holds (Codex round 18,
pre-existing in the base and fixed in its own commit): every retained
reference is copied where it is stored. Tendermint: `Initialize` deep-copies
the client state (`ProofSpecs` through `ics23.ProofSpec.Clone`, including
the leaf prefix and the inner spec's child order and empty child;
`UpgradePath`) and the consensus state's root and next validators hash;
`UpdateState` copies the header's app hash (`NewMerkleRoot` copies its
input) and next validators hash; `RecoverClient` copies the substitute's
consensus state; `VerifyUpgradeAndUpdateState` copies the upgraded client
state's proof specifications and upgrade path and the consensus state's
next validators hash; misbehaviour keeps nothing from the message. Later
client-state replacements (latest or frozen height) share the client's own
copies, never the caller's. Ethereum: `Initialize` copies the genesis
validators root, router address and commitment slot (the fork parameters
are arrays, copied by value) and the consensus state (`copyConsensusState`:
state root, both sync committee summaries); `UpdateState` copies the
execution state root and every sync committee summary it keeps;
`RecoverClient` copies the substitute's consensus state;
`MigrateForkParameters` stores arrays. `ics23`, `extproof` and the merkle
path type keep no state: they verify against what they are given. The core
filetest z7z mutates a client's initialization inputs and a verified
header after the calls, and a proof against the substituted root is
refused.

No exported entry point runs caller-supplied code (Codex round 19): before
any method of a caller-supplied interface value runs, or any caller-supplied
func is called, its dynamic type is established as one of our own concrete
types. Values that are not caller input, verifiers the core already stores,
may be read through a structural interface instead (a recovery's
substitute, through `ethState`; see the table). The exported functions of core, transfer, ibcgov, ethrelay and the
light-client, types and ics23 packages that take an interface, `any` or a
func, and what guards each:

| Entry point | Parameter | Guard |
|---|---|---|
| core `RecvPacket`, `Acknowledgement`, `Timeout` (and `types.Msg*.ValidateBasic`) | `[]ics23.CommitmentProof` | `ics23.CheckProofs` first in `ValidateBasic`: `CommitmentProof_Exist` or `_Nonexist` by value |
| same | `Ext any` | `extproof.FromExt`: a type switch to `extproof.Proof` / `*extproof.Proof`, else ignored; its `Data any` reaches only the Ethereum client's type switch to `MembershipProof` / `*MembershipProof` |
| core `CreateClient` | `lightclient.ClientState`, `ConsensusState` | `checkStates`: `tendermint.ClientState` with `tendermint.ConsensusState`, or `ethereum.ClientState` with `ethereum.ConsensusState`, by value |
| core `UpdateClient` | `lightclient.ClientMessage` | `checkClientMessage`: `*tendermint.MsgHeader`, `*tendermint.Misbehaviour`, `*ethereum.Header`, `*ethereum.Misbehaviour` |
| core `UpgradeClient` | four `any` | the Tendermint client asserts `tendermint.ClientState`, `tendermint.ConsensusState` and `[]ics23.CommitmentProof` before any method, and its `VerifyMembership` runs `ics23.CheckProofs`; the Ethereum client refuses |
| core `CounterpartyValue`, transfer `ProveOutcome` | `proof any` | the Ethereum client's type switch to `MembershipProof` |
| core `RegisterApp` | `app.IBCApp` | no method runs at registration; callbacks are crossing calls (`cross(rlm)`), so they run in the app's own realm, and a non-trusted app needs a governed approval |
| core and transfer `RegisterImpl` | constructor func | runs against the live store only in an authorized installation; the preflight runs it against a fresh, empty store (rounds 17, 29) |
| core store `AddClient`, `SetLightClient`; transfer store `InitExt`, `IterateEscrow` | func | only through the store, held by the installed implementation; mutators guarded by `assertProxyRealm` |
| light clients `Initialize`, `VerifyClientMessage`, `CheckForMisbehaviour`, `UpdateState`, `UpdateStateOnMisbehaviour`, `VerifyUpgradeAndUpdateState` | `lightclient.*` interfaces carrying caller input (states, messages, upgrade values) | type assertion or switch to the package's own concrete types before any method; reached only from the core's guarded paths |
| light clients `RecoverClient`, `CheckRecovery` | `lightclient.Interface`: the substitute, a verifier the core already stores (never caller input) | Tendermint: assertion to `*TMLightClient`; Ethereum: the structural interface `ethState` (`Ethereum() *EthLightClient`), which ethereum/v0's verifier and any installed version wrapping it implement, so a replaced client stays recoverable; only installed verifiers reach it, through the core's governed recovery |
| tendermint `VerifyMembership`, `VerifyNonMembership` | `[]ics23.CommitmentProof` | `ics23.CheckProofs` |
| ethereum `VerifyMembershipProof`, `VerifyNonMembershipProof`, `ProvenValue` | `proof any` | type switch to `MembershipProof` / `*MembershipProof` |
| ibcgov `Govern` | `Request` | a struct with unexported fields, only built by ibcgov's own builders |
| ethrelay | wire bytes | decoded internally to concrete types |

### Delays (§7.5, §9)

At once: tightening (pause, pause app, reject app, block, remove relayer while
others stay, remove member, lowering a denom limit, refusing recipients),
cancels, unpauses (spent under a hold, as §7.4 has GovDAO unpause at once),
a void of packets a guardian named, every Ethereum-bound
decision (dispatched; IBCAdmin applies its own delay). These are every
builder that does not queue: core reject app, pause, pause app, unpause,
unpause app, remove member, remove relayer (while others stay); transfer
block, remove member; route refuse recipients, set denom (when it only
tightens), void (when a guardian named every packet), unpause route;
cancel; every `NewEth*Request`; `NewRemoveExpectationRequest` (it narrows
what notices authorize); `NewRevokeRecapRequest`; `NewRetransmitRequest`
(one re-send of immutable bytes). A denom change is
classified when its decision is recorded, against the configuration then
(another decision may have changed it since the request was built), by
`controls.Loosens`: a new denom, a higher cap floor, supply cap, fee, send
maximum or refund cap, a lower send minimum, and any change of the fee floor
or of the Ethereum token (`Remote`) wait 7 days. The last two are
conservative exceptions to ADR pr6375's immediate tightening: raising the fee
floor also waits. 7 days: everything
else (upgrades, relayers, recovery, approvals, migrations, membership,
enrolment, new denoms and any loosening, a restore of withheld claims (it
resumes payouts), fee collector, unrefusing, credits, sweeps,
losses, recapitalizations, reductions, accepted deficits, reconciliation
settlements, route replacement and reopening, channel binding, every seat
change, a vacancy included, as ADR pr6375 §7.4 has it); revoking a recapitalization authorization applies at once. A
decision whose call would fail on the live state when it applies (the light
client's recovery and migration checks and the core's send checks included)
is refused and spent, never left pending. Proposals
expire 14 days after they are built. A hold defers every queued decision,
except a seat change (a vacancy included) from day 21 of the hold: the
governor cannot end a hold by vacating the flagging seats (z1b).

### Entry points

- **ibcgov**: `Govern`, `Yield`, `Execute`, `Redispatch`, `SetFlag`,
  `ClearFlag`; builders `NewCancelRequest`, `NewSetSeatsRequest`,
  `NewUnpauseRouteRequest`, `NewCore*`/`NewRecoverClientRequest`/
  `NewMigrateClientRequest`, `NewReplaceVerifierRequest`, `NewTransfer*`, route builders
  (`NewEnrollRouteRequest` with the route's bridge contracts,
  `NewSetDenomRequest`, `NewSetFeeCollectorRequest`,
  `NewRefuseRecipientsRequest`, `NewUnrefuseRecipientsRequest`,
  `NewVoidRequest`, `NewRestoreRequest`, `NewCreditRequest`,
  `NewSweepRequest`, `NewRecordLossRequest`, `NewRecapitalizeRequest`,
  `NewRevokeRecapRequest`, `NewReduceRequest`, `NewAcceptDeficitRequest`,
  `NewSettleRequest`,
  `NewReplaceRouteRequest` (with its gno.land suspect height),
  `NewReopenRouteRequest`,
  `NewBindGovernanceRequest`), the epoch notice codec (`EpochNotice`,
  `ParseEpochNotice`) and Ethereum-bound builders `NewEth*Request`
  for kinds 1–13 (`NewEthSettleRequest`, `NewEthReopenRequest`); reads `Flagged`, `PayoutsEpoch`, `NamedSuspect`, `Held`,
  `HoldSince`, `Seat`, `SeatOf`, `Flags`, `RouteIdentity`, `Epoch`, `EpochClient`, `LastSeq`,
  `DispatchBody`, `DispatchState`, `DispatchTransport`, `Decision`,
  `LastDecision`, `Governor`, `Yielded`, `Render` (`""`, `decisions`,
  `dispatch/<e>/<seq>`).
  Guardian bounds: `NewSetSeatsRequest` takes 1 to 6 distinct seat changes
  (`seat:address`, an empty address vacating), at most two of them guardian
  seats, seats 0–3 being guardians and 4–5 watch keys, no address in two
  seats; a vacating change targets the holder the seat had when the request
  was built, and is skipped when it executes if the seat changed hands
  since, while the request's other changes still apply (a request left with
  nothing to change is refused: "nothing to change"); `SetFlag` takes suspect packet keys (comma-separated
  `client/sequence`, the sequence written with 20 digits, at most `MaxKeys`)
  only on a guardian's payouts flag, and a re-assertion replaces the list;
  `PruneFlags` visits 1 to `MaxKeys` (64) entries a call.
- **transfer**: `Claim`, `ClaimRefunds`, `ProveOutcome`, `ContinueReopen`,
  `Recapitalize`, `GovApply` (refuses when the active implementation keeps no
  controls), `ExtView`; renders `routes…` (README).
- **core**: `RetireClient`, `IsClientRetired`, `RetireClientPort`,
  `IsClientRetiredFor`, `MigrateClient`, `VerifierVersion`,
  `ClientRouteIdentity`,
  `ClientTrustGeneration`, `ClientType`,
  `CounterpartyClientID`, `PacketCommitment`, `PacketReceipt`,
  `PacketAcknowledgement`, `HasPendingAsyncAck`, `PendingAsyncAck`,
  `CheckRecoverClient`, `CheckMigrateClient` (read-only dry runs, including
  the light client's `CheckRecovery` and `CheckForkParameters`).
- **types**: `IsValidCustomClientID`, `IsValidRouterClientID` (eureka's
  identifier grammar for the Ethereum router's client ids).

### Governance channel (§5.4)

Source port `gov` on gno.land, destination port `ibcgov` on Ethereum, version
`ibcgov-1`, encoding `application/x-ibcgov`; envelope
`version u8 (1) ‖ epoch u32 ‖ seq u64 ‖ kind u8 ‖ params` (big-endian),
`params = abi.encode(fields…)` of the §5.4 tuple, the whole envelope at
most 1024 bytes (`14 + len(params) ≤ 1024`, the header 14 bytes). Epoch 1
opens when `NewBindGovernanceRequest` binds the channel to an Ethereum client,
which must be Active and the current client of an enrolled transfer route
both when the request is made and when it executes (`checkBindClient`); a
standalone binding is refused, and a client that loses health during the
delay leaves the decision spent. The channel thus always rides a route, and
moves with a route replacement in two phases (ADR pr6375 §7.12, "Governance
epoch switch, two-phase and authenticated"; z9zv, z9zx). ibcgov records the
transitions it expects Ethereum to make, in router client ids, kept apart
from the transfer app's route aliases (`expected`), each bound to the local
gno client governance approves to carry the epoch over the new router
client: `NewEthRouteReplacementRequest(old, new, suspectFrom, localClient)`
dispatches the kind 10 at once and records its transition as a decision of
its own ("expect transition", 7 days, deferred by a hold: approving a local
verifier loosens; a notice before it applies is refused and sent again).
From the dispatch (or the recording of a recovery expectation) the
transition is an intent: it counts against the old client's four
successors at once (a fifth competing kind 10 is refused when built or
dispatched) and keeps its clients open for governance; an intent records
the expectation decisions that own it, and goes only when the last of them
is refused, spent or cancelled, never once active (z9zzd: two kind 10s for
one transition, one cancelled; a kind 10 and a recovery expectation for
one transition). The graph holds at most 64 transitions, pending, active
and tombstoned together (`maxLive`, one joint budget: a chain of 64 steps,
or 16 steps of 4 competing successors; tombstones below): a dispatch or
recovery expectation of a brand-new transition that would pass it is
refused when built and when it applies, and an epoch switch drops every
transition and tombstone whose old router client the new epoch client no
longer reaches through live transitions and tombstones alike, freeing the
capacity (what a surviving tombstone still reaches stays, and keeps using
it). The graph never holds more than 64 distinct transitions and
tombstones; each retention and pruning walk expands every router client
once, so it reads each at most once, at most 64 in all, and a notice-path
walk is bounded by 64 layers of them: there is no "too many to tell" case (z9zza: one transition too
many refused at the cap, accepted after the switch). Every transition must
start from a router client the epoch client reaches (itself included),
checked when built, dispatched or recorded and when its expectation
applies; an expectation applies only to its own intent, still pending and
owned by its decision, so an approval of a transition an epoch switch left
behind is spent, never resurrects it (z9zze: a graph at the cap, every
stale approval and a duplicate spent after the switch, new transitions from
the new epoch client accepted). Each recording of a recovery Request gets
its own parameters, so a Request governed twice owns two places, each
released by its own cancellation (z9zzd), but it grants notice
authority only once its expectation applies (z9zzb: the losers'
expectations applied first never crowd out the winner's; z9zzc: a client on
a pending path, its route replacement executed, stays open for governance
and its expectation, executed last, applies),
and
`NewExpectRecoveryRequest(old, new, localClient)` (7 days, deferred by a
hold: approving a local verifier loosens, and it fits within Ethereum's
30-day recovery delay) records an
emergency recovery's, which ibcgov does not dispatch. The local client must
be an Active Ethereum client, not retired, its counterparty the new router
client, authenticating the identity of the route the channel was bound
over, checked when the decision is built and again when it applies; its
identity alone proves nothing (a client created from a fabricated
checkpoint can copy it), so only the named client is accepted. A router
client has at most 4 expected successors (only one of
competing kind 10s executes on Ethereum). An expectation is never
overwritten. Its lifetime: a pending intent goes when its last owning
decision is refused, spent or cancelled (leaving a tombstone); an active
one goes when an epoch switch leaves it unreachable from the new epoch
client through live transitions and tombstones alike, or by
`NewRemoveExpectationRequest` (below, also leaving a tombstone).
It is not free while it lasts: pending or active, it holds a place among
its old client's 4 successors and the graph's 64, so one never confirmed
by a notice (a cancelled or failed transition) costs capacity until it goes
(this qualifies ADR pr6375 §7.12's "the expectation costs nothing"). A
transition that goes before a switch supersedes it, removed by
`NewRemoveExpectationRequest` or released with its last owning decision
(cancelled, refused or spent), leaves a tombstone in its place: it frees
its place among the old client's 4 successors (which count live
transitions only) and grants no notice authority, but keeps its local
client retained for governance, as if still on an expected path, and so
the local clients of every transition and tombstone beyond it: retention,
supersession and pruning all walk live transitions and tombstones together
from the epoch client. So neither a route replacement nor a prune retires
them for the gov port for good, and they can still be approved again and
carry their notices. Live transitions and tombstones share the joint
budget of 64, and a transition moving between the two leaves the count
unchanged: removing an active expectation, releasing an intent and
approving a tombstoned transition again are never refused for capacity
(the last still needs a successor place); only a brand-new transition
needs a free place. An epoch switch clears a tombstone only when its old
router client is unreachable through either kind (superseded). A
deliberate addition: `NewPurgeTombstoneRequest(old, new, localClient)` (7
days, deferred by a hold: it loosens retirement) drops one tombstone,
freeing its place without a switch; the client, and those beyond it, are
then retired only by the ordinary prune if nothing else retains them, and
if Ethereum did execute the transition the cost is liveness. It is refused
when built and when it applies while a notice recorded as proven may still
be applied along a path through it of the length it needs, the path's
transitions live or tombstoned (`pinnedBy` through both) (z9zzk: a route
moved A→B→C→D here while Ethereum executed A→B and B→C; A→B removed and an
A→D intent cancelled, neither B, C beyond it nor D is retired for
governance, A→B approved again, B's notice switches the epoch, clearing the
A→D tombstone, C's notice follows along B→C, and D is then retired; z9zzl:
A→T removed, A's four successors live and cancelled intents filling the
joint budget, a brand-new transition refused, a loser removed and A→T
approved again, T's notice switches the epoch; z9zzm: the budget full of
junk tombstones, one purged, a brand-new A→X expected and its notice
applied; z9zzn: a purge refused while C's recorded notice needs the
tombstoned B→C, an unrelated one purged; z9zzo: C→D and B→C removed, the
route moved past D, B's notice keeps both tombstones, a prune retires
neither C nor D, both approved again, C's and D's notices apply). A
deliberate addition to ADR pr6375: `NewRemoveExpectationRequest(old, new,
localClient)` removes an active expectation at once, a tightening (it
narrows what notices authorize), so the transitions of cancelled or failed
recoveries and kind 10s do not exhaust the capacity; removing a transition
Ethereum did execute costs only liveness, governance expecting it again
through the 7-day expectation. It is refused for the transition to the
epoch's own client, and while a notice recorded as proven may still be
applied along a path through the transition. That protection is read live,
by the rules `ApplyEpochNotice` applies (`pinnedBy`): every recorded notice
is considered, not only the highest per client; it pins a transition only
if an active path of exactly `e - current` steps from the epoch client's
router counterparty, ending at the notice's source over its client, goes
through it (a transition at step i leaves a router client reached in
exactly i - 1 steps and leads on, in exactly the steps left, to that last
step), and only while the notice's epoch is past the current one and its
client is Active, not retired for the gov port, and at the generation it
was proven under. The walk is bounded by the graph: at most 64 layers of
64 edges, each notice looked up once (z9zzj: Ethereum's recoveries A→X→Y→C
reach epoch 4, governance had removed A→X and filled A's successors with
two-step branches A→Bi→C; C's notice, three steps on, pins none of them,
so a branch is removed, A→X expected again, a transition of the three-step
path is then refused removal, a two-step one is not, and the notice
applies). So it ends by itself, with no record to discard, when the notice
could no longer apply: a generation change (a recovery, a verifier replacement, any
migration), an expiry or a freeze (the client not Active), its retirement,
or supersession (the epoch reaching the notice's). A notice still
applicable that nobody applies (abandoned) keeps pinning only while its
client stays Active at that generation: anyone may apply it with its path,
and once the client expires, unrelayed, the pin ends too. A notice recorded
under an earlier generation is never revived by a later one: the recorded
mark starts afresh at each new generation (z9zzg: four active recovery
expectations; those no notice needs are removed, the one a proven notice
needs refused; the notice's client's verifier is replaced, after which the
one removal applies and its place alone takes a fifth expectation, whose
notice switches the epoch). IBCAdmin, when it executes a kind 10 or
its emergency recovery, raises its epoch by one and sends an epoch notice
from its port `ibcgov` over the new client to port `gov`: `version u8 (1) ‖
epoch u32 ‖ newClient` (big-endian, `newClient` the router's client id it
comes from, the rest of the bytes), version `ibcgov-1`, encoding
`application/x-ibcgov` (gno-eth-ibc `gov-vectors.json` `epochNotice` at
0c55d28, checked in z2c). It is the only packet ibcgov receives
(`App.OnRecvPacket`). How far a notice may move the epoch depends on
nothing Ethereum enforces: whatever IBCAdmin caps or does not, a notice of
any advance is accepted when its whole explicit path lies in the expected
graph, and since the graph holds at most 64 transitions no such path is
longer, so the advance limit is the graph's own bound (`maxNoticeSteps =
maxLive`, 64; z9zzh: a notice 20 steps on, along a chain of 20 recorded
transitions, applied with its 20-step path). When Ethereum is further ahead
than any path the graph holds (its epochs moved by emergency recoveries gno
recorded one by one, or by kind 10s whose expectations were recorded and
applied as the graph freed room), gno catches up in bounded prefixes:
IBCAdmin can resend the notice of any recorded epoch at any time, even after
it was acknowledged, over that epoch's own router client, so the notice of
an intermediate epoch within 64 steps is relayed and applied, the switch
drops the transitions behind it (freeing their places for the next
expectations) and keeps every transition reachable from the new epoch
client, which the rest of the catch-up uses; a notice of a later epoch
recorded as proven before still applies from there (z9zzi: epoch 7's notice
recorded first, the prefix to epoch 4 applied, then epoch 7's from it). Each
prefix's expectations wait their 7 days, so a catch-up of more than 64
steps takes more than one round. Where the gno local client of an
intermediate transition failed, governance recovers it in place
(`NewRecoverClientRequest`, 7 days: it keeps its id, the destination of
Ethereum's packets, and a new trust generation), and the resent notice is
proven through it; where Ethereum's recovery instead created a new router
client, its transition is recorded with a fresh local client by
`NewExpectRecoveryRequest`. A resend is harmless whatever its epoch: the
epoch already switched to, over its client, is answered as a duplicate
(status 3); a notice of a transition the epoch did not take, or of an epoch
already passed over a client still open, gets the universal error
acknowledgement; one over a client the switch retired for governance is
refused by the core (`client … is retired for port gov`, the relay
transaction aborting); in no case does anything change (z9zzi). A notice recorded as proven but not applied is answered with
the universal error acknowledgement, never status 1 or 3: Ethereum does not
count it as acknowledged. A notice of epoch current + k (k from 1 to 64) is
accepted only when the k-th step of a path of expected transitions from
the epoch client's counterparty leads to its source and is bound to exactly
the local client it arrives on, the epoch then adopting that client. The
next step (k = 1) is checked on receipt, among at most 4 edges. A notice
more than one step on, over an approved local client, is recorded as
proven (answered with an error acknowledgement, so IBCAdmin sends it again)
and applied by anyone with `ApplyEpochNotice(epoch, client, path)`, the path
naming each step's router client and local client, verified step by step in
O(k): no search of the expected graph, however it branches, ever refuses an
authentic notice (z9zy: k = 4 over a branching graph, other branches and
local clients refused). Recording first keeps the authentication with the
core's proof, and lets the path come from whoever knows it. A recorded
notice keeps the trust generation of the client that proved it, and applies
only while that client is Active, not retired and at the same generation:
after a freeze, an expiry, a recovery, an upgrade or a verifier replacement
it must be proven afresh. Relaying the original packet again does not do
that: its receipt exists, so the core answers `RESPONSE_NOOP` before any
proof or callback. IBCAdmin sends the identical notice bytes in a fresh
packet (a new transport sequence, `resendEpochNotice(epoch)`), and that
packet is relayed (z9zz relays three such packets). A notice names
the client it came from, its proof verified by the core through that local
client (Active, its counterparty the
notice's source); the epoch then opens there, past any step in between (a
step whose client failed before its notice arrived is skipped: z9zx freezes
one). A gno client on an expected path from the epoch's client (the epoch's
own, the local client of any transition reachable from it, at any
distance: any path in the graph is within a notice's 64 steps, z9zzf, or
one a tombstone retains) is never retired
for the gov port: when its route replacement executes here the core retires
it for the transfer port only (`RetireClientPort`), so a decision in flight,
the kind 10 among them, can still be re-sent and a later step's notice can
still arrive. When a notice moves the epoch, the old epoch's client and
the local clients of the path's intermediate steps (at most 63) are retired
for governance (for good if their route replacement executed here,
otherwise for the gov port, the replacement retiring the rest): the switch
does bounded work. Every other client retired for transfers while on a path
(`awaitingGov`) is retired for good by the permissionless
`PruneGovRetirements(n)` (1 to 64 a call, each resuming where the last
stopped and wrapping round, so a client kept never holds back those after
it) once no path from the epoch's
client goes through it (z9zza: with the graph at the cap and the epoch
unchanged, a replaced client on no path is retired for good at once, one on
a path waits; a switch retires only the old epoch client, then batches). z9zx:
A→B and B→C executed here before any notice, B's notice moves the epoch to
2 and C's to 3, C's for epoch 2 refused; competing kind 10s C→D and C→F,
gno.land's C→F replacement cancelled, D's notice accepted; an emergency
recovery D→G expected by decision, G's notice accepted; G→H→E with H frozen,
E's notice two steps on accepted and one three steps on refused. The app
acknowledgement is `epoch u32 ‖ seq u64 (0) ‖ status u8 ‖ redispatch u8
(0)`: status 1 when the notice switches the epoch, 3 for a notice of the
epoch switched to already (a re-send). Anything else is refused with the
universal error acknowledgement; a notice whose transition is not expected
yet is refused, and IBCAdmin sends it again. Until a notice arrives ibcgov
never sends with a later epoch, so the two sides cannot disagree about the
current epoch.
`seq` is bound in the transaction that records and dispatches the decision, so
numbers are contiguous, never reused or skipped, and their bytes immutable.
Each send is authorized once (client, epoch, seq, payload hash), consumed in
`OnSendPacket`; a direct core send on port `gov` is refused. Acks
(`ParseAck`): error ack, timeout, malformed ack or `redispatch = 1` whatever
the status (a cancel beyond IBCAdmin's window is acked buffered with
`redispatch = 1`) ask for a re-send; statuses 1–5 recorded. Anyone may
re-send any dispatch of the current epoch in a fresh transport packet with
its identical bytes whenever none of its packets is in flight, after any
answer, a success included, since a success acknowledgement can be forged
by a compromised Ethereum-side verifier while the decision never reached
IBCAdmin, leaving a gap later seqs wait behind. IBCAdmin deduplicates by
seq and hash: the same bytes at a seq it holds (recorded, buffered,
executed or spent) are answered `duplicate` (status 3, `redispatch = 0`)
and change nothing there, and a duplicate answering a decision already
acknowledged otherwise leaves its recorded status here as it was. The one
exception is a conflict acknowledged without `redispatch = 1`: IBCAdmin
re-flags itself on every conflict, so a free re-send would let anyone keep
its 7-day decisions deferred. Since a compromised Ethereum-side verifier
can forge a conflict too, governance authorizes one re-send of such a
dispatch by an immediate decision, `NewRetransmitRequest(e, seq)` (a
deliberate addition to ADR pr6375 §5.4; current epoch only, the dispatch
answered with a conflict and no `redispatch`), after checking on Ethereum
that the conflict was fabricated: `IBCAdmin.decision(e, seq)` holds no
decision there, or holds these very bytes (its hash the envelope's), and
no `Conflict(e, seq, …)` event was emitted for it. It is no loosening:
the bytes are immutable and IBCAdmin deduplicates them, so the re-send
records a decision never delivered and is answered duplicate otherwise.
The next `Redispatch` uses the authorization up; another re-send needs
another decision (z2a: a recorded decision re-sent, its duplicate answer
leaving it recorded; a conflict not re-sent freely, re-sent once on an
authorization, then refused again). Router client ids follow eureka's grammar (`client-N`, or a custom
id of up to 128 characters, also in packets); those governance adds (kind 6
op 1, kind 10's new client) must be valid custom ids (4 to 128 characters of eureka's alphabet, not starting with
`client-` or `channel-`). `Redispatch` re-sends identical bytes. Envelopes are
checked byte for byte against gno-eth-ibc's
`contracts/test/fixtures/gov-vectors.json` and against viem
(`ibcgov/filetests/z2b`, `z2c` at gno-eth-ibc 6f94541, kinds 12 and 13
included; `z2e` adds viem vectors and the builders' bounds). Kind 10 carries
`suspectFrom` (an Ethereum block); z2c checks it, and the zero-amount kind 12,
against gno-eth-ibc 6f94541's vectors.

### ADR pr6375 rule → code

| Rule | Code |
|---|---|
| R8, §7.1 meters, claims, fee first, no slivers, round-robin, two accountings, sweeps, meters start empty; a claim's fee is locked when it is credited (`Claim.Fee`), and its first payout's fee portion `min(remainder, claim's fee, denom's fee now)` (a claim reduced below its fee can finish as a fee payment alone; the same turn may also pay the recipient a portion of at least `min(what remains, fee)`) and its later minimum installment `min(remainder, fee)` use the lower of the claim's fee and the denom's fee now, written back to the claim at each payout turn: the fee locked at credit is a ceiling a later raise never passes, and a cut (of the fee, with the cap floor that bounds it) applies and, once a payout turn has seen it, is kept, so no claim is stranded by an installment no recipient meter can hold (sweep entries, refunds and settlements take no fee and pay whole entitlements, so no other entry reads a configuration that could cut one); sweep payments (`PaySweeps`) take live entries of one denom, each paid whole to the decision's payee with no claim fee and outside the payout meters, their total for an `unescrow` denom within the free escrow (what open and withheld claims, queued refunds and proven reservations, `ProvenOwed`, do not reserve: `Reserved()`), deferred under a payouts flag; a credit to a bridge realm is an owed sweep entry, never a claim: the core and transfer proxies, ibcgov, ethrelay, transfer impl/v0 (never registered) and every implementation either proxy's registry lists, read at each receive, so one registered after deployment is covered at once and a replaced one stays covered; the recipient is checked again at payout (`PayClaimsSweeping`): a claim whose recipient became a bridge realm after its credit is not paid but moved to the owed sweep under its packet key, exactly (its remainder leaves `Owed` for `Swept`; the entry carries what the claim paid, which a forged void or forged-receive settlement books as the loss while dropping the remainder; a credit by vote cannot re-credit it, a sweep decision pays it) | `controls/route.gno` (`Credit`, `PayClaims`), `meter.gno` (`Meter`), `transfer/impl/v1/recv.gno`, `controls.gno` (`Claim`), ibcgov `PayoutsEpoch` |
| R8 reachable `Claim` | `transfer/controls.gno`, `ControlsLogic` |
| R9, §7.5, §7.7 ledger, delays, deadline, governor, yield | `decisions/v0`, `ibcgov/governor.gno`, `ledger.gno` |
| R10, §7.4 seats, flags, holds, day 21, naming suspects; a seat's key leaving ends its flags in constant work (seat generations, live flag counts per seat, payouts epochs counting a departed key's payouts flags as cleared then, as of the end of the flag's own seat generation (kept per generation in `genEnds` while entries of that generation remain, so a later key leaving the same seat does not move it, before or after pruning), entries pruned by the permissionless bounded `PruneFlags`; vacating a seat measured at 1,123,231 gas after 5 and after 40 flagged clients); a vacancy is a seat change like any other, 7 days and through a hold no sooner than day 21 (`NewSetSeatsRequest` queues every change; z1b); every Ethereum client flaggable, so a client about to become a route's is held beforehand; every flag operation and check resolves a client to its route's stable key (`routeKeyOf`), and a replacement moves the flags standing under the new client's id to the route (`foldFlags`): a live flag of a seat and function the route has no live flag for moves whole; where the route has one, the two merge into the route's flag, which keeps the earlier time and its own named packet keys first, then takes the new client's keys it lacks only while it holds fewer than 64 (`MaxKeys`), and the new client's flag is removed, so a name beyond the 64 is dropped silently and no longer qualifies a void for immediate execution; guardians check their flags' named keys after a replacement and re-assert any suspect name that was dropped | `ibcgov/guardians.gno` (`flaggable`, `routeKeyOf`, `foldFlags`), `routes.gno` (`mustRoute`) |
| R11, §5.4 gov sender | `ibcgov/ethereum.gno` |
| §6.1–§6.3, §7.1, §7.3 an Ethereum route's packet data | validated by the route's own rules only (`ics20.ValidateBasicEthereum`: amount, sender, base, hops by the router's grammar), never by the SDK's first; a blank or undecodable receiver is an owed sweep entry with a success acknowledgement; a receive that would overflow the route's liabilities is refused by `CheckCredit`, before its acknowledgement, as every other `Credit` check |
| R12, §7.8 send limits, fee, recipient filters (the token itself, a gno-native denom's Ethereum token included); the router, ICS20 transfer, IBCAdmin and every voucher token protected from the enrolment on, no gno-native send before they are set; every route has its own from its enrolment | `controls.DenomConfig`, `Route.Protect`, `transfer/impl/v1/send.gno` (`checkRecipient`), ibcgov `mustBridge` |
| R13, §7.9, §5.4 action 5 one economic loss per packet | every loss carries its packet's direction (a receive on gno.land, `DirRecv`, or a send, `DirSend`) and is stored under that (direction, packet key) identity, the cause kept as metadata; a sweep entry a sweep decision paid is voided as forged on a live route, booking its payout once; the ledger refuses a second loss of the same packet and direction whatever its cause or path (a void as forged, a forged-receive or forged-refund settlement, a recorded loss), and a recorded gno.land loss of a receive represented here (a claim or a sweep entry) is refused: its void or settlement books it | `controls/voids.gno` (`lossID`, `LossBooked`, `RecordLoss`), `refunds.gno` |
| R13, §7.9 voids, restores of withheld claims, credit by vote (receives booked after the activation; pending asynchronous acknowledgements completed), loss ledger by incident with checked totals, recapitalize (authorizations bounded by the incident's unrecovered losses, accepted deficits included, less the unpaid authorizations; revocable, superseded by a later reduction but not by an accepted deficit; funding takes the unrecovered balance down and the unresolved one as far as it goes; only an `unescrow` denom is recapitalized on gno.land; `Recapitalize` takes exactly the authorized amount, native coins sent with a direct call, or a GRC20 drawn from the immediate caller's allowance with no coins attached), reduce open and withheld claims and owed sweep entries, accept. One rule governs every path: a remedy that restores backing or lowers liabilities (a paid recapitalization, a reduction) is bounded by the incident's unrecovered losses, accepted deficits included, and lowers the unresolved balance only as far as it remains, so it may repair an accepted deficit; an acceptance (`Accept`, or a reopening's batches) is bounded by the unresolved losses and lowers only them; a revocation changes neither balance (`accept`, `recover`, `TestRemedyOrder`); a route with a loss of any denom unresolved takes no new exposure, whatever the flags | `controls/voids.gno`, `route.gno` (`ExposureClosed`), `transfer/impl/v1/controls.gno` (`GovApply`), ibcgov route builders |
| §7.5 visible parameter record, §7.4 visible suspects | the guardian flags on the governance page (route keys, suspect packet keys; the page lists flags under enrolled routes only: a flag standing on a client no route has yet still counts toward the hold and is read with `Flags(clientID)`) and the ledger page escape each decision's kind, text and note as inline Markdown (`jsonmd.Text`), so ids such as `_eth_` or `<bridge>` show as written |
| R8, §6.8, §7.1 fee collector | never a realm of the bridge (the transfer realm, the core, ibcgov, ethrelay, any registered implementation): a GRC20 fee paid to the transfer realm is a self-transfer the token refuses, which would stop the route's GRC20 sends and claims; refused by the enrolment and collector builders (`mustCollector`) and again by `GovApply` when the decision executes (z9h) |
| R9, R10, §7.1, §7.9 governed addresses | the transfer proxy's `VoucherSend` and `VoucherApprove` canonicalize their recipient and spender, as do its membership calls; every gno address a builder takes (payees, fee collectors, seats, relayers, members, blocked addresses) is canonicalized (`transfer.CanonicalAddress`) before it is stored or compared, and the transfer implementation canonicalizes a decision's payee again; Ethereum addresses are lowercased |
| R14 authorities | `core/admin.gno`, `app.gno`, `upgrade.gno`, `proposals.gno`; `transfer/admin.gno`, `upgrade.gno`, `proposals.gno`; `authority.NewWithMembers` |
| R16 client migration, two kinds. A verifier replacement (`ethereum-verifier`, params the target version; ibcgov `NewReplaceVerifierRequest(clientID, toVersion)`, 7 days): the conversion is code of a core implementation, declared as plain values (`implv1.NewWithConversions`: from, to, conversion) and installed beforehand by the governed, manifest-checked implementation upgrade (impl/v1 itself declares none); no other code converts a verifier, so no foreign function or object runs. The active implementation's preflight reads its declared pairs and the client's type, status and `VerifierVersion`, and requires the live verifier to expose its ethereum/v0 state (`Ethereum() *EthLightClient`, which the read-only view is built from; a verifier keeping its state otherwise needs migration support of its own); any of these failing spends the decision (z9zl, z9zs); an Active or an Expired client is converted, a Frozen one refused (its misbehaviour is resolved by a recovery first), so a client whose updates stopped long enough to expire is still converted and an ordinary governed recovery then follows (z9zu); the conversion and every check on its result (it names the target version, keeps the live verifier's status, Active or Expired, its latest height and, for a verifier exposing ethereum/v0 state, the slot it trusts consensus states from) run inside one recovered boundary in the core's realm, so a panic (a typed-nil verifier, a status or height that panics) or a mismatch refuses the migration with nothing changed and the decision spent (transfer `z9zn`, `z9zo`); only then is the new verifier installed (`Client.SetLightClient`). The new verifier keeps the history without copying it: the conversion receives only a read-only view of the live verifier (`ethereum.Retire`: copies of its client and consensus states, its latest height, nothing to write with), so a refused conversion leaves nothing half-written (z9zo's tampering conversion); `ethereum.NewFrom` copies the client state and adds the retired verifier's own store to a history index (a persistent tree keyed by the latest slot each retired verifier had, shared with the verifiers it came from and never written through), serving the consensus states of its interval, while the new verifier's own states are stored apart and nothing writes to the retired one again; a height none of the newer stores holds is found by one ordered lookup of that index (the first key at or above it), O(log replacements) however many replacements there were, with no chain of delegations (`TestNewFromFlatHistory`: five replacements, a height from before the first served). The stores' intervals never overlap: a retired store joins the index only when its latest slot is above the index's highest key (it then serves the slots above that key, up to its own), so no key is re-pointed and no older interval is lost. A state a retired store holds at or below the index's highest key (at most the head it inherited, rewritten by a next-committee-only update) is an override of an earlier interval: it is copied into a second persistent, copy-on-write tree (`overrides`, keyed by slot, at most the few heads each replacement carries), consulted before the intervals, so the rewritten head, with the next committee it learned, is served whether or not the verifier's finality advanced before its replacement (`TestNewFromAfterOverlayKeepsHistory`: V1 rewrites the inherited head with its next committee, then, in one case, advances finality; V2 and V3 still serve that head with its committee and the slot from before the first replacement). An Ethereum height is revision 0: every consensus-state lookup refuses another revision first, whichever store would serve its slot, so no state, timestamp or render answers for it (the same test; transfer z9zq renders a pre-conversion slot at revision 0 only). The conversion copies no consensus-state history: it costs O(log previous verifier stores), the persistent trees' insertions copying their search paths (`TestNewFromKeepsHistory`), and every pre-replacement trusted height stays provable (z9zl). The client keeps its id, consensus states, commitments, receipts and acknowledgements, its trust generation advances and its route's payout meters start empty; recovery and fork migration act on the new verifier's head. A fork-schedule migration (`ethereum-fork-schedule`) of the client's verifier, through the `CheckForkParameters`/`MigrateForkParameters` methods it implements (ethereum/v0's, and a later version embedding it, such as `NextVerifier`: z9zl), a verifier without them refused at preflight; `CheckForkParameters`: the client Active; the schedule changed; the genesis fork version and slot unchanged; every fork whose epoch is at or before the current epoch (the later of the latest trusted slot's and the block time's) unchanged, version and epoch; every changed fork activating after the current epoch; the fork epochs in order | `core/verifiers.gno` (`VerifierVersion`), `ethereum/v0` (`NewFrom`, `Retired`, `migrate.gno`), `core/client.gno` (`MigrateClient`), `core/impl/v1` (`NewWithConversions`), ibcgov `NewMigrateClientRequest`, `NewReplaceVerifierRequest`, `ethereum/testing` (`NextVerifier`) |
| R17 flags keep returns open; public Ethereum relaying | `transfer/impl/v1` (flags never touch burns, acks, timeouts), `core/admin.gno` `ensureRelayerFor` |
| R18 route replacement (the new client an Active Ethereum client that is no route's, which on a fresh deployment holds no transfer state, and that authenticates the route's identity: the Ethereum chain id and genesis validators root, the ICS26 router and its commitments slot, recorded from the client at the enrolment (whose bridge router must be the router the client reads) and never changed, checked when the replacement is requested and again when it executes, a client of another chain or router refused however genuine (it would prove that router's receipts: moving a route there is a migration of its own; `core.ClientRouteIdentity`, ibcgov `RouteIdentity`, z9zt); the old one may be frozen or expired; as in Ethereum's reconciliation state machine, it replaces the route's current client whether the route is open or closed, each replacement an incident of its own covering the client it retires, the earlier incidents' records, suspect intervals and counters untouched, a reopening under way aborted, and proofs of every incident's records going through the route's current client): closed until a governed reopening (its loss scan starting over if a loss was booked meanwhile), the payout meters (bridge and recipient) emptied through a new payouts epoch; a fork migration of a route's client empties them too. Refund meters always refill under epoch 0, so their state survives both. The suspect height is a past gno.land height (the builder refuses a negative or future one), and `Registry.Replace` raises one below the previous replacement's height (`ReplacedAt`) to it: a repeated replacement's interval never starts before the client it retires became current | `controls.Registry.Replace`, `Route.Reopen`, transfer `toWire`/`toInternal`, `core.RetireClient`/`RetireClientPort`, ibcgov `NewReplaceRouteRequest` (route identity, payouts epoch), the expected transitions (kind 10 dispatch, `NewExpectRecoveryRequest`), `NewReopenRouteRequest` |
| R19 identifying receipts | `types.CommitPacketReceipt`, `core/store.gno`, `core/impl/v0/packet.gno` |
| §7.3 refusals before state change | `transfer/impl/v1/recv.gno` (`refuse`) |
| §7.11 on-chain records | `controls.Reader` JSON: route totals, and pages `{"entries":[...],"next":<cursor>}` of claims, sweeps, sends (by packet key) and losses (by direction and packet key), `next` being the storage key the following page starts at; `route_*` events. Every Render page is safe Markdown: JSON pages of transfer, core and ibcgov pass through `jsonmd.Inert` (the controls quote with `jsonmd.Quote`), so a raw receiver kept on an owed sweep entry or a path segment echoed in an error is inert text; tables escape counterparty base denoms, paths, counterparty ids and ports, and the route list its denoms (`jsonmd.Cell`, `jsonmd.Text`: sanitize's escapes, then gnoweb's mention and math delimiters, `@` and `$`, as character references, which no sanitize helper covers: `TestMarkdownCellAndText`) |
| §7.12 gno side | route replacement above, naming its suspect height; settlements of a retired client's sends (`Route.SettleRecords`, `NewSettleRequest` and `NewEthSettleRequest` naming a sequence once per direction, an outbound send and an inbound receive of one sequence together: payments checked against the escrow the liabilities still reserve once the whole batch applies, every queued refund and forged claim it releases counted in any item order; whole remainders, zero for a genuine refund paid in full, forged refunds, each record once; a settlement's refund is paid directly, outside the refund meter and, for a minted denom, outside the supply cap, while a refunds hold still defers the decision; the settlement is planned before anything changes (`PlanSettlement`): its genuine refunds take, in item order, the room left for minting (a minted denom: the lower of what the outstanding supply and the voucher token's supply leave under int64) or the free escrow once the whole batch applies (an escrowed one: the lock less what claims, queued refunds and refund reservations still reserve after the batch's releases), and one that does not fit is parked, never refused (`TestEscrowRefundParksThroughReopen`: a forged receive drained the escrow, the genuine refund parked, the route reopened with the forged payout accepted as a deficit, the refund paid once the escrow is whole again); only the refunds paid now are checked against their token or the banker (`payable`), then the plan applies whole (`ApplySettlement`, z9zw). A parked escrowed refund is reserved by `QueuedRefunds` itself, so no claim, sweep payment or receive takes the escrow it waits for. A parked minted refund (reserved in its own total, `Parked`, apart from the in-flight burns' `Returning`, so it never refuses a voucher return; a settlement first releases every reservation and queued refund its batch holds, then adds the parked refunds, then settles the records, so no intermediate sum overflows whatever the item order: `TestParkedRefundLetsReturnsBurn`, `TestSettlementReleasesBeforeParking`): its record is settled (it no longer blocks the reopening), the refund owed and queued (`PayQueued`, in `QueuedRefunds`) and reserved again against the supply cap (`Reservation`, `Parked`), so no credit takes the capacity it needs, and `ClaimRefunds` pays it once the route reopens, in installments as the headroom allows (whatever a voucher return frees, below the usual minimum installment if need be), the refund meter and any refunds hold, the record then `reconciled` (`TestParkedSettlementRefund`); a settlement marks the transfer app's send record and leaves the retired client's commitment in the core as it is); a reopening waits for every open record and every record processed in the suspect interval, of every client a replacement retired, each against its own recorded suspect height (after repeated replacements the controls reader lists the clients still blocking, `ReopenBlockers(route)`, with `SuspectFrom(route, client)` and `OpenSends(route, client)`: `TestReopenBlockersAcrossReplacements`), and runs its deficit acceptance in batches (`ContinueReopen`); `NewRecordLossRequest`; owed refunds reserved; retired client ids final; a retired client takes the authorized app's pending asynchronous acknowledgements |
| R17, §6.7 deployment | a fresh deployment: the transfer proxy's first registration is impl/v1, which serves non-Ethereum clients through impl/v0's logic and puts every Ethereum client under the controls; an Ethereum client carries nothing until `NewEnrollRouteRequest` makes it a route; impl/v0 registers nothing, and the proxy refuses an implementation without the controls once a route exists |
| §7.12 proven outcomes | `transfer.ProveOutcome` reads the destination router's receipt (`ethereum.PacketReceiptCommitment`) and acknowledgement through the replacement client (`core.CounterpartyValue`, which refuses a verifier not Active or retired); an absence counts only at a destination time at or past the packet's timeout; with a matching receipt, the acknowledgement commitment must be exactly one of two: eureka's canonical success (one app acknowledgement, `{"result":"AQ=="}`, `successAckCommitment`), proving delivered, or the universal error acknowledgement, proving refundable; any other commitment, an unwritten one included, is refused ("the destination wrote no final acknowledgement of the packet"), narrower than §5.4's success or error acknowledgement and than ordinary acknowledgement processing (`ack.gno`), which takes any decodable success result; it is safe because an honest eureka ICS20 app writes exactly these two (see Known limits); before any payment for the route, a replacement reserves every refund its retired clients' records may owe and nothing reserves (`PrepareReplacement`, Ethereum review round 20): a success processed at or after the client's suspect height (a forged acknowledgement may have released it) and an escrowed send still pending, each in `ProvenOwed` until its settlement releases it: a proof never releases a reservation, a delivery included, since a proof can be voided later and proven otherwise (Codex round 39: `TestVoidedDeliveryKeepsBacking`); a settlement applying a delivery valid then releases it, and may pay a sibling's refund in the same batch; the walk runs in bounded batches from a cursor, every record visited and every move to the next retired client a step of the budget (`TestPrepareChargesEmptyClients`), so a batch of n takes n budgeted steps plus possibly one final move past a client whose records it has just finished, the first with the replacement itself (64 steps, plus that move), the rest by anyone (`transfer.PrepareReplacement(route, n)`), and until it has walked every record no settlement, sweep payment, credit by vote or reopening applies on the route, so a refund proven and paid first never takes the backing of a sibling still unproven, whatever the proof order (`TestStaggeredProofsKeepSiblingBacking`, `TestStaggeredProofsKeepSiblingSupply`, both crossing a batch boundary); a refund proven owed (refundable, or a collision) on a send whose forged success released what it held is reserved again at once (`ProvenReserve`, counted in `ProvenOwed`: in the escrow's reserved total for an `unescrow` denom, which claims, queued refunds and other settlements never take, and in `booked` for a `mint` denom, against the supply cap) until its settlement releases it, so two such refunds settled by separate decisions never pay the first from the second's backing, nor does a credit in between take it; the reservation survives a proof's invalidation and every later proof, a delivery's included, until the settlement releases it (`TestProvenRefundReservedUntilSettled`, `TestVoidedDeliveryKeepsBacking`); an outcome is final while its verifier stays healthy under the trust generation it was proven in, and void (to be proven again) once the verifier froze, expired, or was recovered, upgraded, migrated or substituted, checked again when the settlement consumes it; a recovered Ethereum client proves nothing from its pre-recovery consensus states; settlement actions must match; action 5 makes a forged receive's claim forged and books what it paid once; a refund paid for a delivered packet is booked only by action 4 |
| §7.13 refund meter, refunds hold, send records for every send | `controls/refunds.gno`, `transfer/impl/v1/ack.gno`, `send.gno`, `controls.gno` (`ClaimRefunds`) |

### Checked arithmetic

Every int64 aggregate of the controls goes through one helper set
(`controls/arith.gno`): `checkedAdd` refuses the operation that would
overflow a liability, reservation or loss total; `mustAdd` covers moves an
earlier check bounds (an overflow there is a broken invariant and aborts);
`boundAdd` saturates sums used only as upper bounds of what is reserved or
booked, which can only make the check they feed refuse more; `statAdd`
saturates statistics no check reads. Audited:

| Aggregate | Rule |
|---|---|
| `InFlight` (what the open sends may still owe: their amounts less what was refunded, an installment coming off at once), `Returning` (the in-flight burns' reservations), `QueuedRefunds` (refunds owed, the parked ones included), `Parked` (settled minted refunds owed), `ProvenOwed` (refunds a send of a retired client may still owe, reserved until its settlement: by a replacement's preparation, a success processed in the suspect interval and an escrowed send still pending; by a proof, a refund proven owed on a send a forged success released) | wide: each can genuinely pass 2^63 (coins escrowed or burned by an open send can be paid out by a claim and sent again while it is open), and no send, acknowledgement, timeout, settlement or proof is refused for it; kept exact beyond int64 (`wide`, two limbs), its int64 view saturating; the checks reading them bound what is reserved (`Reserved`, `booked`, a settlement's free escrow, computed exactly net of what its batch releases), so a saturated view only refuses more (`TestAggregatesNeverWrap`, `TestReturnAfterPartialRefund`) |
| `Owed`, `Withheld`, `Swept` | checked as their sum at every credit (`liabilities`); moves between them must |
| `Outstanding` | checked before every minted payout (a settlement's refund beyond a released reservation is parked when it would overflow: see §7.12 above): a sweep payment that would overflow it is refused whole, its entries kept (the decision spent); a claim installment and a queued refund installment are capped to the headroom, the remainder kept; an immediate refund that would not fit is queued (`TestMintedPayoutHeadroom`) |
| `OpenUnrecovered`, `OpenUnresolved` (denom and incident): the outstanding loss balances | wide (exact beyond int64, views saturating: refunds paid and forged can pass 2^63 in total, and a minted denom has no recapitalization to free capacity), so no loss, void or settlement is refused for them (`TestLossLedgerBeyondInt64`: three losses of MaxInt64/2 settled, then the reopening accepts them all); each booking, payment and reduction is an int64; a reopening accepts an incident's whole unresolved balance at once (`acceptAll`); a recovery (a paid recapitalization, a reduction: `recover`) takes off `OpenUnrecovered`, and off `OpenUnresolved` as far as it remains; an accepted deficit (`accept`) takes off `OpenUnresolved` only |
| `Lost`, `Recapitalized`, `Reduced`, `Accepted` (denom and incident): lifetime totals | stat (saturating), never read by a check |
| a settlement's releases of queued refunds and proven reservations | wide (a batch may release more than int64 holds), the remaining reservation saturated only at the end; its claims' releases are within `Owed` or `Withheld` (`TestSettlementReleasesBeyondInt64`) |
| a settlement's payments | only the refunds paid now, per denom: the escrowed ones take that denom's free escrow once the batch applies, in item order, the minted ones its room left for minting, each int64 and decreasing with each payment, so the payments of each denom never pass that denom's int64 capacity (a batch of several denoms has no combined int64 bound, and none is needed: each denom is paid and checked on its own, `payable` summing per denom); one that does not fit is parked, no payment, adding nothing, and the settlement is never refused for it (`TestMintedRefundsBeyondInt64`, `TestSettlementReserveBeyondMaxInt64`) |
| a settlement's losses | no int64 aggregate refusal: each loss is an int64 booked on its own into the wide loss balances, so a batch's losses may sum past int64 (`TestLossLedgerBeyondInt64`) |
| a sweep payment's total | checked per addition: past int64 it could never be paid at once, so the decision is refused |
| `Reserved`, `booked`, unpaid authorizations, `Route.Unrecovered/Unresolved` (the route-wide sums of the outstanding balances), a reopening's accepted total | bound (saturating) |
| `Credited`, `Paid`, `Fees`, `SweepPaid`, `Sent`, `SendFees`, `Refunded` | stat (saturating) |
| a claim's `Paid`/`Reduced`, a record's `Refunded`, a meter's level | bounded by the claim, the record, the ceiling |
| queue and refund sequences, authorization ids, open and pending record counts | grow by one per entry, record or authorization inserted (a settlement can queue up to 64 parked refunds, and a transaction can make several calls): far below int64 in any chain's lifetime |
| impl/v1: a send's amount plus the route fee | checked |

### Governed execution never aborts

Every decision ibcgov executes refuses deterministically, spending the
decision, on the failures below that the live state could later clear (by
preflight before crossing, or a refusal returned by the callee). An
implementation switch is checked in the preflight against an empty store
(its built version, and its install hook's declared condition through
`InstallChecker`), so a candidate that disagrees with its manifest or
refuses the active implementation is spent (z1m). What can still roll back
and leave a queued decision pending is only what the preflight cannot
evaluate: a panic in candidate code itself (a constructor or hook panicking,
which crosses the realm boundary unrecovered), a constructor whose result
depends on the store it is handed, or a hook refusing on a condition it
does not declare through `InstallChecker`. A verifier replacement is not: its conversion runs on a read-only view of the live verifier that
returns copied states (a retired verifier's consensus states included), a
panic in it recovered,
and a converted verifier that fails its checks is refused before anything
is installed, so the decision is spent:

| Decision | Failure conditions refused |
|---|---|
| core/transfer update impl | not registered; the candidate's manifest does not install over the active version; the candidate built against an empty store reports another version than its manifest (or, for transfer, another controls answer), or its install hook refuses the active implementation (`CheckUpdateImpl`, `InstallChecker`); a transfer implementation without the route controls once a route has them (the controls are never rolled back) |
| core add/remove relayer | listed already / not listed |
| core recover client | unknown, retired, mismatched or wrong-status clients; the light client's own check (`CheckRecoverClient`) |
| core migrate client | unknown, retired or non-Ethereum client; no migrating implementation; the light client's check (`CheckMigrateClient`); for a verifier replacement, a conversion the active implementation does not declare from the client's verifier version to the target, the client neither Active nor Expired (Frozen) or not Ethereum, a verifier exposing no ethereum/v0 state (`Ethereum() *EthLightClient`, which the conversion reads: z9zs), and, returned by the core, a conversion that panics or a converted verifier of another version, of another status than the live one, at another latest height, or trusting consensus states from another slot |
| core approve app | no pending registration; port taken |
| core reject app | no pending registration |
| core pause / pause app / unpause / unpause app | paused already / no app / not paused |
| core/transfer add/remove member | member already / not a member / ibcgov itself |
| transfer block/unblock | blocked already / not blocked |
| route operations (`GovApply`) | every refusal returned, including no controls installed; a sweep payment or settlement refund that its token or the banker would refuse (`payable`, checked per denom before anything changes: a valid recipient other than the transfer realm, the voucher token and its supply room, the registered GRC20 and this realm's balance, the escrow accounting and the bank balance; z9zr), the entitlement kept; a sweep payment under a payouts flag, or a settlement paying refunds under a refunds hold, is deferred (stays pending) rather than spent |
| route enrollment | as `GovApply`; the client no longer usable (`checkRouteClient` again at execution: not Active, retired on any port (governance's included: a client an epoch notice moved past, `core.IsClientRetiredAny`), not Ethereum, no counterparty, a route's already), or naming no route identity, or reading another router than the bridge's (z9zt), before either realm changes |
| route replacement | as `GovApply`; the new client unusable (retired on any port: a stale replacement to a client governance moved past, z9zzb); the route's client moved; the new client no longer authenticating the route's identity (z9zt) |
| bind governance | bound already; not Active, or not the current client of an enrolled route |
| seats | an address in two seats; nothing to change |
| unpause route | spent under a hold; no flag |
| cancel | not pending |
| Ethereum-bound kinds | channel unbound; envelope too long; past epoch (cancel); the core's send refusals (paused, app paused, client retired, inactive, uncounterparted, latest consensus time past the timeout) |

Tests: z1e, z1f, z1h, z1i, z1j, z2e (ibcgov), z9zj, z9zk, z9zt, z9zu (transfer).

### Parameters (§9)

Compiled: 7-day delay, 14-day deadline, 24-hour hold linger, day 21 of a hold,
`MaxClaims` 20, `MaxKeys` 64, `MaxOpenRecaps` 64 (unpaid recapitalization
authorizations an incident holds on a denom at once; a further one is
refused until one is paid or revoked), `ReopenBatch` 64 (a reopening batch takes at
most 64 incidents, then at most 64 authorizations), `PageLines` 100 (each
paginated controls page returns at most 100 entries), envelope 1024 bytes, gov packet timeout 6 hours,
the governor key (placeholder). Per route and denom, set by decision at
launch: the cap floor (10,000 tokens/day in base units), fee (20, floor 2,
ceiling cap/4), send max 25,000 and min 40, refund cap (the day cap), the
Ethereum token of a gno-native denom, mint cap and supply cap of Ethereum
tokens. Recipient meters are cap/4. A minted denom's supply starts at its
vouchers in circulation when it is enabled.

`NewSetDenomRequest` takes a denom of 1 to 128 ASCII characters among
letters, digits and `/:._-` (`isDenom`); a `mint` configuration may name
its token by its Ethereum address (`0x…`), which becomes its voucher's IBC
denom over the route's stable key (`ics20.NewDenom(token,
NewHop("transfer", route)).IBCDenom()`), and a minted denom must be such an
`ibc/` denom, an unescrowed one must not. A denom configuration is refused unless (`DenomConfig.Validate`,
`Route.SetDenom`): the cap floor is positive; the fee floor is positive and
`FeeFloor ≤ Fee ≤ CapFloor/4` (the configured cap floor, not a larger
lock-derived day cap); the refund cap is positive; an `unescrow` denom has
`0 < SendMin ≤ SendMax`, no supply cap and a non-zero lower-case Ethereum
token (`Remote`); a `mint` denom has a positive supply cap, no send limits
and no `Remote` (its base is its token). A denom's accounting never changes,
and its cap floor never goes below the value it was enabled with
(`LaunchCapFloor`). A minted denom's supply cap bounds what is booked
against it, the one authoritative equation:
`booked = Outstanding + Returning + Parked + ProvenOwed + Owed + Withheld + Swept`
(vouchers in circulation; returning sends' reservations, the in-flight burns;
settled refunds parked for want of supply; refunds reserved by a
replacement's preparation or a proof on sends a forged success released;
and every claim and sweep entry owed). The terms do not overlap: a refund
queued by an acknowledgement or timeout keeps its burn's reservation in
`Returning` (it is not counted again by `QueuedRefunds`, which is not a term
here); a parked refund leaves `Returning` for `Parked` when its record
settles; a `ProvenOwed` reservation is taken only on a send whose
`Returning` reservation a success released, and the settlement releases it.
A credit is admitted only within the cap, `amount <= SupplyCap - booked`,
the sum saturating. It governs admission
only: lowering it below what is already booked refuses new credits until
the booked total falls under it, and keeps every booked obligation and its
payouts (claims and sweep payments are checked against the int64 headroom,
not the cap).

The rendered route JSON (`routes/<route>`) shows each meter as stored: its
level and time as of its last refill (`meter`, `refund_meter`), not what it
holds now. `controls.Reader.Meters` (route, denom, recipient, now, the
payouts epoch and its time from `ibcgov.PayoutsEpoch`, the lock) returns the
bridge and recipient bucket levels refilled to now under that epoch, on
copies. They bound a payout; what a `Claim` actually pays also depends on a
`payouts` flag, a closed route or unresolved loss (nothing is paid), the
escrow queued refunds and refund reservations hold (`unescrow`: a claim
payout is bounded by the lock less `QueuedRefunds` plus `ProvenOwed`), the outstanding supply's
headroom (`mint`), the claim's remainder, and the installment rules (the
fee first and whole, then no slivers below `min(remainder, fee)`).

The Ethereum-bound builders bound what they take, on the source side: a
settlement (`NewEthSettleRequest`) names 1 to 8 items (`maxSettleItems`,
what a 1024-byte envelope holds with a 64-byte client id; a longer client id
leaves room for fewer, the envelope bound refusing the excess), a cancel
(`NewEthCancelRequest`) 1 to 14 ranges (78 + 64 bytes a range: no more fit
the envelope), each within the numbers already dispatched in the current
epoch, and a role decision (`NewEthRoleRequest`)
never names `ADMIN_ROLE` (0) or `PUBLIC_ROLE` (`MaxUint64`). A voucher registration (`NewEthVoucherRequest`, kind 5) takes a
base denom only in the transfer app's wire grammar, the one IBCAdmin's
`canonicalGnoDenom` must accept exactly (`isGnoWireDenom`): a native denom
`[a-z][a-z0-9]{2,15}`, or a GRC20 alias `gno.land:r` then at least two
`:`-separated gno package names (`[a-z][a-z0-9]*`, `_` or `-` only between
alphanumerics, so `gno.land:r:my-org:token` is one), then optionally `.` and
a slug of 1 to 32 characters of `[A-Za-z0-9_-]`, at most 128 bytes; a
realm-issued coin (`/gno.land/r/...:denom`) never travels and is refused.

## Divergences from ADR pr6375

1. **Port**: destination port `ibcgov` (eureka refuses custom ports under four
   characters; agreed with gno-eth-ibc's `IBCAdmin.PORT`). Source port `gov`.
   The ADR now says the same.
2. **Envelope bound 1024**, not 512: kind 6 with gno.land's real merkle prefix
   encodes to 558 bytes (same on the Ethereum side); the ADR now says the same.
3. **The fee is not refunded** with a refunded send; refunds pay the amount.
4. **Any clearing of a payouts flag starts a new payouts epoch** (owner clears
   included), so meters restart empty more often than in bridges.
5. **Holds are global on gno.land**: two guardian seats flagging anything on any
   route make the hold.
6. **Route keys**: a route's key is its first client id; the route is
   enrolled by a decision naming an existing Ethereum client, not by GovDAO
   creating the client. Creating a client, Ethereum ones included, needs a
   listed relayer while the whitelist names any (open to anyone only while it
   is empty); governance vets the client it names. Relaying for an existing
   Ethereum client (update, receive, acknowledgement, timeout) is open to
   anyone.
7. **ibcgov is not upgradeable** (no proxy): its port and ledger are permanent,
   as `IBCAdmin`'s are; a defect needs a new realm and the core's and transfer's
   `IBCGovPath` constants cannot follow it once those proxies are deployed.
8. **Refund meters start empty** at enrolment of the denom, like the other
   meters. A refund is paid at once only if the whole of it fits the refund
   meter, the escrow covers it (an `unescrow` denom) and no older refund is
   queued; otherwise it joins the denom's queue. `ClaimRefunds` pays the
   queue first in, first out, stopping at a head it cannot pay, in
   installments of at least `min(remainder, max(1, RefundCap/24))`, except
   that a minted installment is cut to the supply's headroom when that is
   less (any positive amount: a parked refund larger than any headroom a
   return frees is still paid).
9. **Ethereum-bound decisions are not deferred by gno-side holds**: their delay
   and deferral run on Ethereum (§6.6).
10. **Conservative choices where the ADR is silent**:
    - a route with a loss of any denom that has no restoring decision takes
      no new exposure (no gno-native send, credit, claim payout or sweep
      payment), not only kept flagged; voucher returns, acknowledgements,
      timeouts and refunds go on, under the refund meter and refunds hold;
    - a credit by vote only replaces a sweep entry booked at the receipt
      after the route's enrolment, for the entry's current whole amount
      (what the packet carried less any reduction since), at least the
      current fee; one completing a pending asynchronous acknowledgement is
      for exactly what the packet carried;
    - only a withheld void is restored; a forged void and a voided sweep entry
      are final;
    - a voucher return waits until its denom is enabled on the route, so every
      send has a record;
    - a flag may stand on any Ethereum client id, enrolled or not, so a
      client about to become a route's can be held beforehand;
    - settlements apply only to the sends of a client a replacement retired,
      as on Ethereum, and a genuine refund the free escrow (or, minted, the
      room left for minting) cannot pay is parked, as Ethereum parks it:
      owed and reserved, never refusing the settlement.
11. **A retired client is marked, not frozen**: where ADR pr6375 freezes the
    replaced client, the core proxy records it as retired
    (`coreStore.retired`). Its verifier's status is unchanged (core `z16b`:
    `retired: true status: Active`); the core refuses every new packet
    message on it, except that the app that registered a packet's port may
    still write the pending asynchronous acknowledgement of a packet received
    before the retirement.

### Changes affecting every route

The controls are Ethereum-only, but these changes reach every client of the
core and the transfer app, Tendermint ones included. Each is deliberate, a
protection or a governance rule, and each has a test documenting the base
(1e0c7c5) behaviour next to the new one:

| Change | Base behaviour | Test |
|---|---|---|
| A packet receipt identifies its packet, `types.CommitPacketReceipt` (R19), so a different packet at a received sequence aborts | the receipt was the constant `0x02`, and a different packet at a received sequence returned `RESPONSE_NOOP` | core `z7p` |
| Relayer and authority administration of the core and transfer app is governance-only, through ibcgov (R14) | a deployer authority added and removed relayers and members | core `z12*`, `z14*`, transfer `z8*`, ibcgov `z1c` |
| A client can be retired (`RetireClient`, by a route replacement) and carries a trust generation, bumped by every recovery, freeze, upgrade, migration and substitution | no retirement, no generation | core `z9*`, `z8a`, `z16a` |
| The core keeps its own copy of a counterparty's merkle prefix | the core kept the caller's slice, so its later change moved the client's proof namespace | core `z16g` (Tendermint), `z16f` (Ethereum) |
| The core keeps its own copy of the packet it holds for an asynchronous acknowledgement | the core kept the relayer's payload slices, so their later change changed the packet the acknowledgement is written for | core `z10a` (Tendermint) |
| `VoucherSend` and `VoucherApprove` (and the authority membership calls) canonicalize their address | an uppercase recipient or spender got a balance or allowance under that string, which the canonical address cannot use | transfer `z4aaaa` (Tendermint), `z9w` |
| A voucher's grc20 symbol, and its grc20reg key `<transfer realm>.<symbol>`, are allocated from the voucher id counter when it is created (`IBC-` and the id in base 36: `IBC-1`, `IBC-2`, ...), stored with it and read by `VoucherSymbol`, `GRC20RegKey` and the renders; the full IBC hash stays its identity (its denom, the grc20reg slug), so no denom can take another's registry key | the symbol was the hash's first 11 hex characters, so a denom ground to share a future voucher's prefix registered first and made that voucher's receive abort on grc20reg's duplicate key | transfer `z9zp` (two colliding hashes, both usable); the old and new symbols and keys side by side in `z0c`, `z0d`, `z0e`, `z1aa`, `z2aaa`, `z3aa`, `z4a`, `z4aaaa`, `z5aa`, `z6a` |
| A Tendermint light client keeps copies of what it trusts: `Initialize` deep-copies the client state (proof specifications, upgrade path) and the consensus state's root and next validators hash, `UpdateState` the header's app hash and next validators hash, `RecoverClient` the substitute's consensus state, `VerifyUpgradeAndUpdateState` the upgraded proof specifications, upgrade path and next validators hash; `NewMerkleRoot` copies its input; `Initialize` runs once | the client kept the caller's slices, so writing them after `CreateClient` or a verified `UpdateClient` moved the trusted root and state without verification | core `z7z` (Tendermint), tendermint `TestInitializeOnce` |
| No entry point runs a caller-supplied implementation: commitment proofs must be `ics23.CommitmentProof_Exist` or `_Nonexist` by value (`ics23.CheckProofs`, in every message's `ValidateBasic` and the Tendermint client's membership and absence checks), client and consensus states and client messages the light clients' own types (core `checkStates`, `checkClientMessage`) | the core called `GetExist`, `ClientType` and `ValidateBasic` on whatever the caller passed, running its code in the core's realm context | core `z16e`, `z1b`, `z1j` (a caller's own state type, refused up front; the base's unhandled-type and client-type-naming branches are unreachable with our own types); `z1f`, `z1i`, `z2d`, `z2f` reach the base's type-mismatch and `ValidateBasic` errors with real Tendermint and Ethereum states and headers; ics23 `TestCheckProofs`; tendermint `TestVerifyRefusesOwnProofTypes` |
| Every JSON render passes through `jsonmd.Inert`, Markdown-active characters in strings written as escapes; the Markdown pages escape user strings | strings were JSON-quoted only, or written raw | transfer `z9v`, ibcgov `z2d`, `z1k` |

Identifier validation is not among them: `Packet.ValidateBasic` and
`Hop.ValidateBasic` keep the SDK's rule, byte-identical to the base; the
ICS26 router's client id grammar (custom ids of up to 128 characters) is
`Packet.ValidateBasicRouter`, which the core applies only to an Ethereum
client's packets, and denom hops take it only where an Ethereum route
extracts its own denoms (types `TestPacketClientIDsAreTheBase`, ics20
`TestHopValidationIsTheBase`).

Nor are the packet limits (core README, Packet limits): every route keeps the
SDK's `types.MaximumPayloadsSize`, 262,144 bytes of payload data (the sum of
`len(Payload.Value)`, not the wire message), its port and id lengths and its
timeout bounds (on send, at most 24 hours ahead). An oversized send aborts.
An oversized receive, an Ethereum route's included, is a core refusal before
the transfer app runs: no claim or sweep entry is booked, and no receipt or
error acknowledgement is written, so the packet stays pending at the router
until it times out and is refunded there.

### Deployment manifest

`scripts/packages.sh` lists every package in deploy order;
`scripts/check-packages.sh` (run by `make test`) fails when a listed
package's deployed code imports a `gno.land/[pr]/aib` package the manifest
does not list before it.

## Consequences

- Every loosening power waits 7 days and passes through one ledger, visible on
  ibcgov's page, which lists the newest 100 pending and the newest 100
  settled decisions of each kind (`decisions.PageMax`): an older pending
  decision stays executable but drops off that page, so operators read the
  complete ledger with `Render("decisions")` (JSON) or `Decision(id)`; tightening applies at once (see Delays): unpauses, member
  removals and a relayer's removal while others remain are immediate, and
  GovDAO keeps its immediate tightening powers.
- A forged Ethereum delivery is bounded by the meters and stopped by a payouts
  flag; a forged refund by the refund meter and the refunds hold.
- Every send and every receive has a packet-keyed record a reconciliation can
  authenticate; receipts identify packets.
- Gas and storage grow per transfer (records, claims). Records are never
  pruned (a pruning policy is an open question of ADR pr6375). An Ethereum
  client's consensus states grow likewise, one per accepted finalized
  height, with no pruning path; a recovery only stops trusting the older
  ones, which stay stored.
- Relayers must call `Claim` and `ClaimRefunds`, relay governance packets and
  call `Redispatch`. Receipt values changed from `0x02` to a hash.
- Payouts to a recipient blocked after its credit are still paid (the
  blocklist is checked at receive).

## Known limits

- **Refunds wait for a reconciliation's reopening** (a deliberate exception
  to ADR pr6375's refund liveness): a route closed by a replacement pays no
  queued refund and no parked one (`ClaimRefunds` pays nothing while
  closed), whatever the flags. A genuine refund stays owed and reserved,
  and is paid after the reopening, so its liveness depends on the
  reconciliation finishing, which is governed and bounded (7-day decisions,
  batches anyone may run). Paying refunds on a closed route would pay
  forged ones the reconciliation has not yet told apart.

- **A recapitalization authorized and not paid when a route reopens** is
  revoked: the reopening records the remaining unresolved losses as an
  accepted deficit.
- **The pending asynchronous acknowledgement path of a credit by vote** cannot
  be exercised end to end: the transfer app never answers asynchronously, so
  no transfer packet waits for one. The core side (retired clients taking the
  app's acknowledgement) and the controls side are tested separately.
- **Reconciliation recognizes two acknowledgement commitments only**
  (§7.12 proven outcomes): eureka's canonical success, one app
  acknowledgement `{"result":"AQ=="}`, and the universal error
  acknowledgement. Any other commitment under a matching receipt is refused,
  though ordinary acknowledgement processing accepts any success result that
  decodes. An honest eureka ICS20 app writes exactly these two (it answers
  synchronously, success as `{"result":"AQ=="}`, failure through the
  router's universal error acknowledgement), so an honest destination is
  always provable. A packet whose destination wrote anything else (another
  app, or a later ICS20 with another success encoding) cannot be proven, and
  so cannot be settled, until an implementation that recognizes its
  commitment is installed.
- **Replacement does no per-denom work**: its candidate check reads the
  core and the registry only. `ExposureClosed`, checked on every gno-native
  send and every receive (a voucher return checks none: it is exit only),
  reads a count of the denoms with an unresolved loss (`unresolvedDenoms`,
  kept by every loss, acceptance and recovery); settling or rejecting a
  queued refund finds it through an index by packet key (`refundIdx`), in
  logarithmic work; a reopening's blocker check reads an index of the
  retired clients that still block it (`blocking`, kept by every change to a
  retired client's open or suspect records), in logarithmic work, whatever
  the number of replacements (`TestBoundedIndexes`). Walks that remain: the
  recapitalization paths walk only the incident's open authorizations,
  indexed per denom and incident and at most `MaxOpenRecaps` (64):
  authorizing makes two such scans (the open total, then the count against
  the cap), paying one (the total), a reduction one (`revokeConflicting`:
  the total once, then revoking newest first), and an explicit revocation
  goes to its authorization directly; the reopening's deficit acceptance
  and authorization revocation, in bounded batches (`ContinueReopen`).
  `ProveOutcome` and a settlement's plan check that the record's client is
  one a replacement retired from the route through the index of retired
  clients' suspect heights (`retiredHere`, `suspect`), in logarithmic work
  whatever the route's replacement history, not by scanning `Replaced`;
  the replacement's preparation runs in bounded batches. A
  hold's seat count and a seat's
  removal are constant work (live flag counts per seat, seat generations).
- **A settlement is final once it applies** (an accepted residual of the
  reconciliation): a gno settlement (`NewSettleRequest`) and Ethereum's
  kind 12 (`NewEthSettleRequest`) apply after their 7-day delay, and until
  then a hold defers them, and the outcomes they rest on are void when the
  proving verifier is no longer Active (an expiry, computed from time,
  which changes no generation) or its trust generation changed (a
  recovery, a freeze, an upgrade, a migration or verifier substitution). Once applied, a compromise of that verifier
  found later does not reopen them: a record settled as delivered, or a
  refund settled as forged, on a fabricated proof stays settled, and later
  incidents reconcile only the records still open. On gno.land no governed
  path in the bridge pays such a user afterwards: a credit by vote needs a
  receive's sweep entry, and a reduction or an accepted deficit pays no
  one, so compensation lies outside these controls. The defense is the
  delay itself: a settlement is planned against outcomes proven through a
  replacement verifier, and the guardians' hold covers the 7 days in which
  a compromise of it can be found.
- **A compromised notice verifier, or a poisoned intermediate client, is
  not recoverable inside ibcgov** (accepted residuals; ADR pr6375 trusts
  an approved notice verifier). An approved local client that authenticates
  a forged notice before it is caught moves the governance epoch: the
  switch retires the clients it passes and prunes the graph, and no
  decision undoes it. Whether that loses Ethereum-bound governance depends
  on whether Ethereum can reach the epoch and client gno adopted: a
  premature forged notice naming the epoch and client a legitimate kind 10
  already recorded will establish costs nothing, since Ethereum executes it
  normally and its genuine notice is answered as a duplicate, dispatches
  going over the adopted client meanwhile. A local client kept Active by forged updates at every
  prefix endpoint within 64 steps blocks a catch-up past 64, since recovery
  needs a Frozen or Expired subject. Only Ethereum-bound decisions are lost
  meanwhile: gno-side governance (core, transfer, routes) does not depend
  on the epoch. What exists, and nothing more:
  - after a forged switch, Ethereum's emergency recovery (if enabled on
    IBCAdmin) to a fresh router client heals it: governance records the
    recovery's expectation from the router counterparty of gno's current
    epoch client, wherever the forged switch left it, over a fresh healthy
    local client, and the recovery's notice switches from there. Its epoch
    must be above gno's and within 64 of it: if the forged notice put gno
    ahead of Ethereum, Ethereum needs as many recoveries (30 days each) as
    pass gno's epoch, gno recording each step's expectation so the path
    exists;
  - a poisoned client is frozen by misbehaviour (two valid updates
    finalizing different headers at one slot, or a different root at a slot
    it holds) when such updates exist, or expires if its updates stop; it is
    then recovered in place (`NewRecoverClientRequest`) and the resent
    notice proven through it;
  - nothing else: core and transfer accept loosening governance only from
    ibcgov's fixed package path (`IBCGovPath`, a constant of their immutable
    proxies), so GovDAO cannot point them at a freshly deployed ibcgov,
    and ibcgov, plain code with its ledger, sequences and epoch, cannot be
    replaced; GovDAO keeps only its tightening powers (pausing the core or
    an app, rejecting an app). IBCAdmin is immutable too. When Ethereum
    cannot reach the adopted epoch and client, by a decision it already
    holds or by its emergency recovery, Ethereum-bound governance is lost
    for good.
- **Pre-recovery consensus states of a Tendermint client** stay usable, as in
  ibc-go: only the Ethereum light client marks them untrusted, and only
  Ethereum clients prove outcomes for settlement. The trust generation is
  kept for every client all the same.
- **Deleted for a fresh deployment.** Round 8 removed the legacy
  fallback: `Registry.Legacy`, `Route.Legacy`, `Denom.Legacy`,
  `Route.LegacyDenom`, the legacy refund cap (`OpLegacyRefundCap`,
  `SetLegacyRefundCap`), the per-client bridge sets and their union
  (`OpBridge`, `SetBridge`, `Bridge`, `IsBridgeContract`), `Enroll`'s
  adoption of a legacy route and the reader's legacy view. Round 10 removed
  the whole v0 to v1 migration: the staged activation
  (`NewTransferActivateControlsRequest`, its decision, `stagingGap`,
  `sentDenom`, `parseStagedDenoms`, the 8-route, 16-denom and 64-packet
  caps), the first-controls check of `NewTransferUpdateImplRequest`,
  backfill (`transfer.Backfill`, `ControlsLogic.Backfill`, `Route.Backfill`,
  `SendRecord.Backfilled`), the import gate (`Route.Unimported`,
  `StartImport`, its credit and reopening checks), the transfer proxy's
  per-client asset counters and outstanding payloads (`ClientAssetCount`,
  `HoldsAsset`, `InFlightPayloads`), `core.OutstandingSends` and its
  per-port commitment counts, the legacy-receipt check of a credit by vote,
  impl/v1's `CheckInstall`, impl/v0's registration, and the filetests of
  those paths.
- **The e2e suite** (`e2e/`) needs the Docker devnet; its build makes the test
  key ibcgov's launch governor and divides the delays by 60480. The guardians'
  holds, which flags on any Ethereum client suffice for (no enrolled route
  needed), are covered by filetests only.
