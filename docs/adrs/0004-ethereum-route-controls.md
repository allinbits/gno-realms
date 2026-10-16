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
still change; once deployed they freeze (ADR 0001, 0002).

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
    retired client → route key; every Ethereum client's bridge contracts
    (router, ICS20 transfer, IBCAdmin) the activation or an enrolment
    named, and the union of them.
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
    released or consumed once), reconciliation settlement (once), backfilled,
    and a proven outcome with its verifier and the verifier's trust
    generation at the proof.
  - Per client, the processed send records not settled by reconciliation,
    ordered by processing height (an `avl.Node`, so the records processed at
    or after a replacement's suspect height are counted in logarithmic work);
    per retired client, its suspect height.
  - Escrow stays in the proxy's existing per-key accounting, keyed by the
    route key (= the first client id, so pre-existing escrow carries over).
- **ibcgov**: `ledger`, `yielded`, `seats[6]`, `flags` (route|fn|seat),
  `routes` (route key → payouts epoch), `holdSince`/`belowSince`, `epoch`,
  `epochs` (epoch → client, last seq), `dispatches` ((epoch, seq) → bytes,
  status, transport sequence), `pendingAuth` (one-time, never persisted
  between transactions in practice: set and consumed in the same call).

### Authorities (R14)

| Operation | Who |
|---|---|
| `core.Pause`, `PauseApp`, `RejectApp`; `transfer.BlockAddress` | authority members: GovDAO proxy (proposals in the realms) and ibcgov. No deployer. |
| `core.Unpause`, `UnpauseApp`, `ApproveApp`, `AddRelayer`, `RemoveRelayer`, `RecoverClient`, `UpdateImpl`, `MigrateClient`, `RetireClient`, membership; `transfer.UnblockAddress`, `UpdateImpl`, membership, `GovApply` | ibcgov only (`cur.Previous().PkgPath() == IBCGovPath`) |
| ibcgov decisions | the governor (`Govern`, MsgRun) until `Yield()`, then GovDAO proposals only (`req.Proposal()`) |
| ibcgov `Execute`, `Redispatch`; transfer `Claim`, `ClaimRefunds`, `Backfill`, `Recapitalize` | anyone |
| ibcgov `SetFlag`, `ClearFlag` | the seat's key, on a route ibcgov enrolled or any Ethereum client (the key of a legacy fallback route); a client of a route, current or retired, names its route (flags are kept under the route key) |
| `UpdateClient`, `RecvPacket`, `Acknowledgement`, `Timeout` on an Ethereum client | anyone (R17); other clients keep the relayer whitelist |

### Delays (§7.5, §9)

At once: tightening (pause, pause app, reject app, block, remove relayer while
others stay, remove member, lowering a denom limit, refusing recipients),
cancels, unpauses (spent under a hold), a void of packets a guardian named, a
restore of withheld claims, seat vacating, every Ethereum-bound decision
(dispatched; IBCAdmin applies its own delay). 7 days: everything else
(upgrades, relayers, recovery, approvals, migrations, membership, enrolment,
new denoms and any loosening, fee collector, unrefusing, credits, sweeps,
losses, recapitalizations, reductions, accepted deficits, reconciliation
settlements, route replacement and reopening, channel binding, seat
additions); revoking a recapitalization authorization applies at once. A
decision whose call would fail on the live state when it applies (the light
client's recovery and migration checks and the core's send checks included)
is refused and spent, never left pending. Proposals
expire 14 days after they are built. A hold defers every queued decision,
except a seat change from day 21 of the hold.

### Entry points

- **ibcgov**: `Govern`, `Yield`, `Execute`, `Redispatch`, `SetFlag`,
  `ClearFlag`; builders `NewCancelRequest`, `NewSetSeatsRequest`,
  `NewUnpauseRouteRequest`, `NewCore*`/`NewRecoverClientRequest`/
  `NewMigrateClientRequest`, `NewTransfer*`, route builders
  (`NewEnrollRouteRequest` with the route's bridge contracts,
  `NewSetDenomRequest`, `NewSetFeeCollectorRequest`,
  `NewRefuseRecipientsRequest`, `NewUnrefuseRecipientsRequest`,
  `NewVoidRequest`, `NewRestoreRequest`, `NewCreditRequest`,
  `NewSweepRequest`, `NewRecordLossRequest`, `NewRecapitalizeRequest`,
  `NewRevokeRecapRequest`, `NewReduceRequest`, `NewAcceptDeficitRequest`,
  `NewSettleRequest`,
  `NewReplaceRouteRequest` (with its gno.land suspect height),
  `NewReopenRouteRequest`, `NewTransferActivateControlsRequest` (impl/v1
  with its first route, its bridge contracts and 0 to 16 denoms, in one
  transaction, with the bridge contracts of every other Ethereum client the
  core holds; the only way to install the first implementation with the
  controls: `NewTransferUpdateImplRequest` refuses that, and reinstalls one
  over an active controls implementation),
  `NewBindGovernanceRequest`) and Ethereum-bound builders `NewEth*Request`
  for kinds 1–13 (`NewEthSettleRequest`, `NewEthReopenRequest`); reads `Flagged`, `PayoutsEpoch`, `NamedSuspect`, `Held`,
  `HoldSince`, `Seat`, `SeatOf`, `Flags`, `Epoch`, `EpochClient`, `LastSeq`,
  `DispatchBody`, `DispatchState`, `DispatchTransport`, `Decision`,
  `LastDecision`, `Governor`, `Yielded`, `Render` (`""`, `decisions`,
  `dispatch/<e>/<seq>`).
- **transfer**: `Claim`, `ClaimRefunds`, `Backfill`, `ContinueReopen`,
  `Recapitalize`, `GovApply` (refuses when the active implementation keeps no
  controls), `ExtView`; renders `routes…` (README).
- **core**: `RetireClient`, `IsClientRetired`, `MigrateClient`,
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
`params = abi.encode(fields…)` of the §5.4 tuple, at most 1024 bytes. Epoch 1
opens when `NewBindGovernanceRequest` binds the channel to an Ethereum client;
a route replacement over that client opens the next epoch over the new one.
`seq` is bound in the transaction that records and dispatches the decision, so
numbers are contiguous, never reused or skipped, and their bytes immutable.
Each send is authorized once (client, epoch, seq, payload hash), consumed in
`OnSendPacket`; a direct core send on port `gov` is refused. Acks
(`ParseAck`): error ack, timeout, malformed ack or `redispatch = 1` whatever
the status (a cancel beyond IBCAdmin's window is acked buffered with
`redispatch = 1`) → re-dispatchable (current epoch only); statuses 1–5
recorded. Router client ids follow eureka's grammar (`client-N`, or a custom
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
| R8, §7.1 meters, claims, fee first, no slivers, round-robin, two accountings, sweeps, meters start empty | `controls/route.gno` (`Credit`, `PayClaims`, `Meter`), `transfer/impl/v1/recv.gno`, `controls.gno` (`Claim`), ibcgov `PayoutsEpoch` |
| R8 reachable `Claim` | `transfer/controls.gno`, `ControlsLogic` |
| R9, §7.5, §7.7 ledger, delays, deadline, governor, yield | `decisions/v0`, `ibcgov/governor.gno`, `ledger.gno` |
| R10, §7.4 seats, flags, holds, day 21, naming suspects; every effective Ethereum route flaggable, legacy fallback routes included; every flag operation and check resolves a client to its route's stable key (`routeKeyOf`), and a replacement moves the flags standing under the new client's id to the route (`foldFlags`) | `ibcgov/guardians.gno` (`flaggable`, `routeKeyOf`, `foldFlags`), `routes.gno` (`mustRoute`) |
| R11, §5.4 gov sender | `ibcgov/ethereum.gno` |
| R12, §7.8 send limits, fee, recipient filters (the token itself, a gno-native denom's Ethereum token included); the router, ICS20 transfer, IBCAdmin and every voucher token protected from the enrolment on, no gno-native send before they are set; the staged activation names every Ethereum client's bridge contracts, so a legacy fallback route protects its client's from its creation, and one whose client was never named (created after the activation) refuses every known bridge contract | `controls.DenomConfig`, `Route.Protect`, `Registry.SetBridge`, `transfer/impl/v1/send.gno` (`checkRecipient`), ibcgov `mustBridge`, `mustOtherBridges` |
| R13, §7.9 voids, restores of withheld claims, credit by vote (receives booked after the activation; pending asynchronous acknowledgements completed), loss ledger by incident with checked totals, recapitalize (authorizations revocable, superseded by a later reduction or accepted deficit), reduce claims and owed sweep entries, accept; a route with a loss of any denom unresolved takes no new exposure, whatever the flags | `controls/voids.gno`, `route.gno` (`ExposureClosed`), `transfer/impl/v1/controls.gno` (`GovApply`), ibcgov route builders |
| R9, R10, §7.1, §7.9 governed addresses | every gno address a builder takes (payees, fee collectors, seats, relayers, members, blocked addresses) is canonicalized (`transfer.CanonicalAddress`) before it is stored or compared, and the transfer implementation canonicalizes a decision's payee again; Ethereum addresses are lowercased |
| R14 authorities | `core/admin.gno`, `app.gno`, `upgrade.gno`, `proposals.gno`; `transfer/admin.gno`, `upgrade.gno`, `proposals.gno`; `authority.NewWithMembers` |
| R16 fork migration | `ethereum/v0/migrate.gno`, `core/client.gno` (`MigrateClient`), `core/impl/v1` |
| R17 flags keep returns open; public Ethereum relaying | `transfer/impl/v1` (flags never touch burns, acks, timeouts), `core/admin.gno` `ensureRelayerFor` |
| R18 route replacement: closed until a governed reopening (which also waits for every impl/v0 send left outstanding at the enrolment to be backfilled and settled, and re-checks everything when its last batch would open the route), meters emptied | `controls.Registry.Replace`, `Route.Reopen`, transfer `toWire`/`toInternal`, `core.RetireClient`, ibcgov `NewReplaceRouteRequest` (+ `nextEpoch`, payouts epoch), `NewReopenRouteRequest` |
| R19 identifying receipts | `types.CommitPacketReceipt`, `core/store.gno`, `core/impl/v0/packet.gno` |
| §7.3 refusals before state change | `transfer/impl/v1/recv.gno` (`refuse`) |
| §7.11 on-chain records | `controls.Reader` JSON: route totals, claims, sweeps, sends, losses; `route_*` events. Every Render page is safe Markdown: JSON pages of transfer, core and ibcgov pass through `jsonmd.Inert` (the controls quote with `jsonmd.Quote`), so a raw receiver kept on an owed sweep entry or a path segment echoed in an error is inert text; tables escape counterparty base denoms, paths, counterparty ids and ports, and the route list its denoms (`sanitize.TableCell`, `InlineText`) |
| §7.12 gno side | route replacement above, naming its suspect height; settlements of a retired client's sends (`Route.SettleRecords`, `NewSettleRequest`: whole remainders, zero for a genuine refund paid in full, forged refunds, each record once); a reopening waits for every open record and every record processed in the suspect interval, and runs its deficit acceptance in batches (`ContinueReopen`); `NewRecordLossRequest`; owed refunds reserved; retired client ids final; a retired client takes the authorized app's pending asynchronous acknowledgements |
| R17, §6.7 activation | `NewTransferActivateControlsRequest`: the switch to impl/v1, the first route's enrolment and its denoms, and a positive legacy refund cap, in one decision; the legacy path (`Registry.Legacy`, `Route.LegacyDenom`) records and meters the returns of every other client and denom impl/v0 used until a decision enrols or enables them; the import gate (`core.OutstandingSends`, `Route.Unimported`) keeps a route's credits off until its outstanding impl/v0 sends are backfilled |
| §7.12 proven outcomes | `transfer.ProveOutcome` reads the destination router's receipt (`ethereum.PacketReceiptCommitment`) and acknowledgement through the replacement client (`core.CounterpartyValue`, which refuses a verifier not Active or retired); an absence counts only at a destination time at or past the packet's timeout; an outcome is final while its verifier stays healthy under the trust generation it was proven in, and void (to be proven again) once the verifier froze, expired, or was recovered, upgraded, migrated or substituted, checked again when the settlement consumes it; a recovered Ethereum client proves nothing from its pre-recovery consensus states; settlement actions must match; action 5 makes a forged receive's claim forged and books what it paid once; a refund paid for a delivered packet is booked only by action 4 |
| §7.13 refund meter, refunds hold, send records for every send, backfill of older ones | `controls/refunds.gno`, `transfer/impl/v1/ack.gno`, `send.gno`, `controls.gno` (`ClaimRefunds`, `Backfill`) |

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
| `InFlight` (open sends' amounts) | checked at every send and backfill: bounds every refund owed |
| `QueuedRefunds`, `Returning` | must (≤ `InFlight`) |
| `Owed`, `Withheld`, `Swept` | checked as their sum at every credit (`liabilities`); moves between them must |
| `Outstanding` | must on moves (claim payouts, sweep payments, refunds within a reservation); checked for a settlement's refund beyond a released reservation |
| `Lost` (denom and incident) | checked (`lossFits`), batch sums checked per addition; `addLoss` refuses to wrap |
| `Recapitalized`, `Reduced`, `Accepted` (denom and incident) | must: bounded by the incident's losses |
| a settlement's payments, queued refunds and losses; a sweep payment's total | checked per addition |
| `Reserved`, `booked`, unpaid authorizations, `Route.Unrecovered/Unresolved`, a reopening's accepted total | bound (saturating) |
| `Credited`, `Paid`, `Fees`, `SweepPaid`, `Sent`, `SendFees`, `Refunded` | stat (saturating) |
| a claim's `Paid`/`Reduced`, a record's `Refunded`, a meter's level | bounded by the claim, the record, the ceiling |
| queue and refund sequences, authorization ids, open and pending record counts | grow by one per transaction |
| impl/v1: a send's amount plus the route fee | checked |

### Governed execution never aborts

Every decision ibcgov executes refuses deterministically, spending the
decision, on any failure the live state could later clear (by preflight
before crossing, or a refusal returned by the callee):

| Decision | Failure conditions refused |
|---|---|
| core/transfer update impl | not registered; the candidate refuses the active implementation as its predecessor (`CheckUpdateImpl`, `InstallChecker`); a transfer implementation without the route controls once a route has them (the controls are never rolled back) |
| transfer activate controls | as above; the candidate keeps no controls; the route is a route or unusable; a staged denom accounted otherwise |
| core add/remove relayer | listed already / not listed |
| core recover client | unknown, retired, mismatched or wrong-status clients; the light client's own check (`CheckRecoverClient`) |
| core migrate client | unknown, retired or non-Ethereum client; no migrating implementation; the light client's check (`CheckMigrateClient`) |
| core approve/reject app | no pending registration; port taken |
| core pause / pause app / unpause / unpause app | paused already / no app / not paused |
| core/transfer add/remove member | member already / not a member / ibcgov itself |
| transfer block/unblock | blocked already / not blocked |
| route operations (`GovApply`) | every refusal returned, including no controls installed; a sweep payment under a payouts flag, or a settlement paying refunds under a refunds hold, is deferred (stays pending) rather than spent |
| route replacement | as `GovApply`; the new client unusable; the route's client moved; still closed from the previous replacement |
| bind governance | bound already; unusable client |
| seats | an address in two seats; nothing to change |
| unpause route | spent under a hold; no flag |
| cancel | not pending |
| Ethereum-bound kinds | channel unbound; envelope too long; past epoch (cancel); the core's send refusals (paused, app paused, client retired, inactive, uncounterparted, latest consensus time past the timeout) |

Tests: z1e, z1f, z1h, z1i, z1j, z2e (ibcgov), z9m (transfer).

### Parameters (§9)

Compiled: 7-day delay, 14-day deadline, 24-hour hold linger, day 21 of a hold,
`MaxClaims` 20, `MaxKeys` 64, envelope 1024 bytes, gov packet timeout 6 hours,
the governor key (placeholder). Per route and denom, set by decision at
launch: the cap floor (10,000 tokens/day in base units), fee (20, floor 2,
ceiling cap/4), send max 25,000 and min 40, refund cap (the day cap), the
Ethereum token of a gno-native denom, mint cap and supply cap of Ethereum
tokens. Recipient meters are cap/4. A minted denom's supply starts at its
vouchers in circulation when it is enabled.

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
   enrolled by a decision naming an existing Ethereum client (anyone may create
   clients; governance vets the one it names), not by GovDAO creating the
   client.
7. **ibcgov is not upgradeable** (no proxy): its port and ledger are permanent,
   as `IBCAdmin`'s are; a defect needs a new realm and the core's and transfer's
   `IBCGovPath` constants cannot follow it once those proxies are deployed.
8. **Refund meters start empty** at enrolment of the denom, like the other
   meters; queued refunds are paid in installments of at least an hour of the
   refund cap.
9. **Ethereum-bound decisions are not deferred by gno-side holds**: their delay
   and deferral run on Ethereum (§6.6).
10. **Conservative choices where the ADR is silent**:
    - a route with a loss of any denom that has no restoring decision takes
      no new exposure (no gno-native send, credit, claim payout or sweep
      payment), not only kept flagged; voucher returns, acknowledgements,
      timeouts and refunds go on, under the refund meter and refunds hold;
    - a credit by vote only replaces a sweep entry booked at the receipt
      after the route's activation (or completes a pending asynchronous
      acknowledgement), for exactly what the packet carried;
    - only a withheld void is restored; a forged void and a voided sweep entry
      are final;
    - a voucher return waits until its denom is enabled on the route, so every
      send has a record; the staged activation enables the route's denoms
      with the upgrade, so no return waits on a live route;
    - the staged activation may stage no denom (the route then carries only
      voucher returns until a denom is enabled); the ordinary transfer
      switch never installs the first controls implementation, so the
      legacy refund cap is always set with the controls;
    - a flag may stand on any Ethereum client id, enrolled or not, so a
      legacy fallback route can be held from its first voucher return;
    - settlements apply only to the sends of a client a replacement retired,
      as on Ethereum, and a settlement whose payments exceed the free escrow
      is refused whole (Ethereum parks the payment instead).

### Deployment manifest

`scripts/packages.sh` lists every package in deploy order;
`scripts/check-packages.sh` (run by `make test`) fails when a listed
package's deployed code imports a `gno.land/[pr]/aib` package the manifest
does not list before it.

## Consequences

- Every loosening power waits 7 days and passes through one ledger, visible on
  ibcgov's page; GovDAO keeps immediate tightening powers.
- A forged Ethereum delivery is bounded by the meters and stopped by a payouts
  flag; a forged refund by the refund meter and the refunds hold.
- Every send and every receive has a packet-keyed record a reconciliation can
  authenticate; receipts identify packets.
- Gas and storage grow per transfer (records, claims). Records are never
  pruned (a pruning policy is an open question of ADR pr6375).
- Relayers must call `Claim` and `ClaimRefunds`, relay governance packets and
  call `Redispatch`. Receipt values changed from `0x02` to a hash.
- Payouts to a recipient blocked after its credit are still paid (the
  blocklist is checked at receive).

## Known limits

- **Vacating seats is immediate** (§7.5 removals), so a decision can remove the
  flagging guardians and end a hold 24 hours later; the day-21 rule only
  governs replacements. A route with unresolved losses stays closed all the
  same.
- **A recapitalization authorized and not paid when a route reopens** is
  revoked: the reopening records every unrecovered loss as an accepted
  deficit.
- **The pending asynchronous acknowledgement path of a credit by vote** cannot
  be exercised end to end: the transfer app never answers asynchronously, so
  no transfer packet waits for one. The core side (retired clients taking the
  app's acknowledgement) and the controls side are tested separately.
- **A legacy denom's refunds are metered** at the activation's legacy refund
  cap until a decision enables the denom with its own; the return itself is
  never refused.
- **Pre-recovery consensus states of a Tendermint client** stay usable, as in
  ibc-go: only the Ethereum light client marks them untrusted, and only
  Ethereum clients prove outcomes for settlement. The trust generation is
  kept for every client all the same.
- **A legacy route for a client created after the activation** (never named
  by it, never enrolled) does not know its own bridge contracts: it refuses
  every bridge contract any other client's route named, which covers a
  client sharing the same Ethereum deployment, not one of another
  deployment.
- **The e2e suite** (`e2e/`) needs the Docker devnet; its build makes the test
  key ibcgov's launch governor and divides the delays by 60480. The guardians'
  holds need an Ethereum route and are covered by filetests only.
