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
| ibcgov `Execute`, `Redispatch`; transfer `Claim`, `ClaimRefunds`, `ProveOutcome`, `ContinueReopen`, `Recapitalize` | anyone |
| ibcgov `SetFlag`, `ClearFlag` | the seat's key, on a route ibcgov enrolled or any Ethereum client (one about to become a route's); a client of a route, current or retired, names its route (flags are kept under the route key) |
| `UpdateClient`, `RecvPacket`, `Acknowledgement`, `Timeout` on an Ethereum client | anyone (R17); other clients keep the relayer whitelist |

Candidate implementation code reaches the store only through an authorized
installation: the bootstrap registration, or a governed `UpdateImpl` after
its 7-day delay. Each implementation registers, beside its constructor, a
store-free manifest of plain values (`RegisterImpl(cur, ctor, version,
over[, keepsControls])`: the version it reports, the versions it installs
over, and for transfer whether it keeps the route controls). The preflights
`CheckUpdateImpl` (core and transfer) and `transfer.KeepsControls` read the
manifest only: no candidate code runs and nothing is handed the store or a
stored object before approval; the installation checks the built
implementation against its manifest. Paths by which code could reach a
store or a mutable stored object, swept (Codex round 17): the preflights
above (were building the candidate with the live store; now
manifest-only); the installation itself (authorized only); the active
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
| core and transfer `RegisterImpl` | constructor func | runs only in an authorized installation (store-free manifest, round 17) |
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
a void of packets a guardian named, seat vacating, every Ethereum-bound
decision (dispatched; IBCAdmin applies its own delay). These are every
builder that does not queue: core reject app, pause, pause app, unpause,
unpause app, remove member, remove relayer (while others stay); transfer
block, remove member; route refuse recipients, set denom (when it only
tightens), void (when a guardian named every packet), unpause route; set
seats (removals only); cancel; every `NewEth*Request`. A denom change is
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
  `NewBindGovernanceRequest`) and Ethereum-bound builders `NewEth*Request`
  for kinds 1–13 (`NewEthSettleRequest`, `NewEthReopenRequest`); reads `Flagged`, `PayoutsEpoch`, `NamedSuspect`, `Held`,
  `HoldSince`, `Seat`, `SeatOf`, `Flags`, `Epoch`, `EpochClient`, `LastSeq`,
  `DispatchBody`, `DispatchState`, `DispatchTransport`, `Decision`,
  `LastDecision`, `Governor`, `Yielded`, `Render` (`""`, `decisions`,
  `dispatch/<e>/<seq>`).
  Guardian bounds: `NewSetSeatsRequest` takes 1 to 6 distinct seat changes
  (`seat:address`, an empty address vacating), at most two of them guardian
  seats, seats 0–3 being guardians and 4–5 watch keys, no address in two
  seats; `SetFlag` takes suspect packet keys (comma-separated
  `client/sequence`, the sequence written with 20 digits, at most `MaxKeys`)
  only on a guardian's payouts flag, and a re-assertion replaces the list;
  `PruneFlags` visits 1 to `MaxKeys` (64) entries a call.
- **transfer**: `Claim`, `ClaimRefunds`, `ProveOutcome`, `ContinueReopen`,
  `Recapitalize`, `GovApply` (refuses when the active implementation keeps no
  controls), `ExtView`; renders `routes…` (README).
- **core**: `RetireClient`, `IsClientRetired`, `MigrateClient`,
  `VerifierVersion`,
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
opens when `NewBindGovernanceRequest` binds the channel to an Ethereum client,
which must be Active and the current client of an enrolled transfer route
both when the request is made and when it executes (`checkBindClient`); a
standalone binding is refused, and a client that loses health during the
delay leaves the decision spent. The channel thus always rides a route: a
route replacement over that client, the way out of a frozen or expired
client, opens the next epoch over the new one.
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
| R8, §7.1 meters, claims, fee first, no slivers, round-robin, two accountings, sweeps, meters start empty; a claim's fee is locked when it is credited (`Claim.Fee`), and its first installment `min(remainder, claim's fee, denom's fee now)` (a claim reduced below its fee can finish as a fee payment alone) and its later minimum installment `min(remainder, fee)` use the lower of the claim's fee and the denom's fee now, written back to the claim at each payout turn: the fee locked at credit is a ceiling a later raise never passes, and a cut (of the fee, with the cap floor that bounds it) applies and, once a payout turn has seen it, is kept, so no claim is stranded by an installment no recipient meter can hold (sweep entries, refunds and settlements take no fee and pay whole entitlements, so no other entry reads a configuration that could cut one); sweep payments (`PaySweeps`) take live entries of one denom, each paid whole to the decision's payee with no claim fee and outside the payout meters, their total for an `unescrow` denom within the free escrow (what open and withheld claims and queued refunds do not reserve), deferred under a payouts flag; a credit to a bridge realm is an owed sweep entry, never a claim: the core and transfer proxies, ibcgov, ethrelay, transfer impl/v0 (never registered) and every implementation either proxy's registry lists, read at each receive, so one registered after deployment is covered at once and a replaced one stays covered; the recipient is checked again at payout (`PayClaimsSweeping`): a claim whose recipient became a bridge realm after its credit is not paid but moved to the owed sweep under its packet key, exactly (its remainder leaves `Owed` for `Swept`; the entry carries what the claim paid, which a forged void or forged-receive settlement books as the loss while dropping the remainder; a credit by vote cannot re-credit it, a sweep decision pays it) | `controls/route.gno` (`Credit`, `PayClaims`), `meter.gno` (`Meter`), `transfer/impl/v1/recv.gno`, `controls.gno` (`Claim`), ibcgov `PayoutsEpoch` |
| R8 reachable `Claim` | `transfer/controls.gno`, `ControlsLogic` |
| R9, §7.5, §7.7 ledger, delays, deadline, governor, yield | `decisions/v0`, `ibcgov/governor.gno`, `ledger.gno` |
| R10, §7.4 seats, flags, holds, day 21, naming suspects; a seat's key leaving ends its flags in constant work (seat generations, live flag counts per seat, payouts epochs counting a departed key's payouts flags as cleared then, as of the end of the flag's own seat generation (kept per generation in `genEnds` while entries of that generation remain, so a later key leaving the same seat does not move it, before or after pruning), entries pruned by the permissionless bounded `PruneFlags`; vacating a seat measured at 1,123,231 gas after 5 and after 40 flagged clients); every Ethereum client flaggable, so a client about to become a route's is held beforehand; every flag operation and check resolves a client to its route's stable key (`routeKeyOf`), and a replacement moves the flags standing under the new client's id to the route (`foldFlags`) | `ibcgov/guardians.gno` (`flaggable`, `routeKeyOf`, `foldFlags`), `routes.gno` (`mustRoute`) |
| R11, §5.4 gov sender | `ibcgov/ethereum.gno` |
| §6.1–§6.3, §7.1, §7.3 an Ethereum route's packet data | validated by the route's own rules only (`ics20.ValidateBasicEthereum`: amount, sender, base, hops by the router's grammar), never by the SDK's first; a blank or undecodable receiver is an owed sweep entry with a success acknowledgement; a receive that would overflow the route's liabilities is refused by `CheckCredit`, before its acknowledgement, as every other `Credit` check |
| R12, §7.8 send limits, fee, recipient filters (the token itself, a gno-native denom's Ethereum token included); the router, ICS20 transfer, IBCAdmin and every voucher token protected from the enrolment on, no gno-native send before they are set; every route has its own from its enrolment | `controls.DenomConfig`, `Route.Protect`, `transfer/impl/v1/send.gno` (`checkRecipient`), ibcgov `mustBridge` |
| R13, §7.9, §5.4 action 5 one economic loss per packet | every loss carries its packet's direction (a receive on gno.land, `DirRecv`, or a send, `DirSend`) and is stored under that (direction, packet key) identity, the cause kept as metadata; a sweep entry a sweep decision paid is voided as forged on a live route, booking its payout once; the ledger refuses a second loss of the same packet and direction whatever its cause or path (a void as forged, a forged-receive or forged-refund settlement, a recorded loss), and a recorded gno.land loss of a receive represented here (a claim or a sweep entry) is refused: its void or settlement books it | `controls/voids.gno` (`lossID`, `LossBooked`, `RecordLoss`), `refunds.gno` |
| R13, §7.9 voids, restores of withheld claims, credit by vote (receives booked after the activation; pending asynchronous acknowledgements completed), loss ledger by incident with checked totals, recapitalize (authorizations bounded by the incident's unrecovered losses, accepted deficits included, less the unpaid authorizations; revocable, superseded by a later reduction but not by an accepted deficit; funding takes the unrecovered balance down and the unresolved one as far as it goes; only an `unescrow` denom is recapitalized on gno.land; `Recapitalize` takes exactly the authorized amount, native coins sent with a direct call, or a GRC20 drawn from the immediate caller's allowance with no coins attached), reduce open and withheld claims and owed sweep entries, accept. One rule governs every path: a remedy that restores backing or lowers liabilities (a paid recapitalization, a reduction) is bounded by the incident's unrecovered losses, accepted deficits included, and lowers the unresolved balance only as far as it remains, so it may repair an accepted deficit; an acceptance (`Accept`, or a reopening's batches) is bounded by the unresolved losses and lowers only them; a revocation changes neither balance (`accept`, `recover`, `TestRemedyOrder`); a route with a loss of any denom unresolved takes no new exposure, whatever the flags | `controls/voids.gno`, `route.gno` (`ExposureClosed`), `transfer/impl/v1/controls.gno` (`GovApply`), ibcgov route builders |
| §7.5 visible parameter record, §7.4 visible suspects | the guardian flags on the governance page (route keys, suspect packet keys; the page lists flags under enrolled routes only: a flag standing on a client no route has yet still counts toward the hold and is read with `Flags(clientID)`) and the ledger page escape each decision's kind, text and note as inline Markdown (`sanitize.InlineText`), so ids such as `_eth_` or `<bridge>` show as written |
| R9, R10, §7.1, §7.9 governed addresses | the transfer proxy's `VoucherSend` and `VoucherApprove` canonicalize their recipient and spender, as do its membership calls; every gno address a builder takes (payees, fee collectors, seats, relayers, members, blocked addresses) is canonicalized (`transfer.CanonicalAddress`) before it is stored or compared, and the transfer implementation canonicalizes a decision's payee again; Ethereum addresses are lowercased |
| R14 authorities | `core/admin.gno`, `app.gno`, `upgrade.gno`, `proposals.gno`; `transfer/admin.gno`, `upgrade.gno`, `proposals.gno`; `authority.NewWithMembers` |
| R16 client migration, two kinds. A verifier replacement (`ethereum-verifier`, params the target version; ibcgov `NewReplaceVerifierRequest(clientID, toVersion)`, 7 days): the conversion is code of a core implementation, declared as plain values (`implv1.NewWithConversions`: from, to, conversion) and installed beforehand by the governed, manifest-checked implementation upgrade (impl/v1 itself declares none); no other code converts a verifier, so no foreign function or object runs. The active implementation's preflight reads its declared pairs and the client's type, status and `VerifierVersion` (an undeclared conversion spends the decision: z9zl); the conversion and every check on its result (it names the target version, is Active, keeps the latest height) run inside one recovered boundary in the core's realm, so a panic (a typed-nil verifier, a status or height that panics) or a mismatch refuses the migration with nothing changed and the decision spent (transfer `z9zn`, `z9zo`); only then is the new verifier installed (`Client.SetLightClient`). The new verifier keeps the history without copying it: `ethereum.NewFrom` copies the client state and holds a read-only view of the retired verifier (`Retired`), serving every consensus state at or below its latest slot, while the new verifier's own states are stored apart and nothing writes to the retired one again; constant work whatever the history (`TestNewFromKeepsHistory`), every pre-replacement trusted height stays provable (z9zl). The client keeps its id, consensus states, commitments, receipts and acknowledgements, its trust generation advances and its route's payout meters start empty; recovery and fork migration act on the new verifier's head. A fork-schedule migration (`ethereum-fork-schedule`) of the client's verifier, through the `CheckForkParameters`/`MigrateForkParameters` methods it implements (ethereum/v0's, and a later version embedding it, such as `NextVerifier`: z9zl), a verifier without them refused at preflight; `CheckForkParameters`: the client Active; the schedule changed; the genesis fork version and slot unchanged; every fork whose epoch is at or before the current epoch (the later of the latest trusted slot's and the block time's) unchanged, version and epoch; every changed fork activating after the current epoch; the fork epochs in order | `core/verifiers.gno` (`VerifierVersion`), `ethereum/v0` (`NewFrom`, `Retired`, `migrate.gno`), `core/client.gno` (`MigrateClient`), `core/impl/v1` (`NewWithConversions`), ibcgov `NewMigrateClientRequest`, `NewReplaceVerifierRequest`, `ethereum/testing` (`NextVerifier`) |
| R17 flags keep returns open; public Ethereum relaying | `transfer/impl/v1` (flags never touch burns, acks, timeouts), `core/admin.gno` `ensureRelayerFor` |
| R18 route replacement (the new client an Active Ethereum client that is no route's, which on a fresh deployment holds no transfer state; the old one may be frozen or expired; as in Ethereum's reconciliation state machine, it replaces the route's current client whether the route is open or closed, each replacement an incident of its own covering the client it retires, the earlier incidents' records, suspect intervals and counters untouched, a reopening under way aborted, and proofs of every incident's records going through the route's current client): closed until a governed reopening (its loss scan starting over if a loss was booked meanwhile), the payout meters (bridge and recipient) emptied through a new payouts epoch; a fork migration of a route's client empties them too. Refund meters always refill under epoch 0, so their state survives both. The suspect height is a past gno.land height (the builder refuses a negative or future one), and `Registry.Replace` raises one below the previous replacement's height (`ReplacedAt`) to it: a repeated replacement's interval never starts before the client it retires became current | `controls.Registry.Replace`, `Route.Reopen`, transfer `toWire`/`toInternal`, `core.RetireClient`, ibcgov `NewReplaceRouteRequest` (+ `nextEpoch`, payouts epoch), `NewReopenRouteRequest` |
| R19 identifying receipts | `types.CommitPacketReceipt`, `core/store.gno`, `core/impl/v0/packet.gno` |
| §7.3 refusals before state change | `transfer/impl/v1/recv.gno` (`refuse`) |
| §7.11 on-chain records | `controls.Reader` JSON: route totals, and pages `{"entries":[...],"next":<cursor>}` of claims, sweeps, sends (by packet key) and losses (by direction and packet key), `next` being the storage key the following page starts at; `route_*` events. Every Render page is safe Markdown: JSON pages of transfer, core and ibcgov pass through `jsonmd.Inert` (the controls quote with `jsonmd.Quote`), so a raw receiver kept on an owed sweep entry or a path segment echoed in an error is inert text; tables escape counterparty base denoms, paths, counterparty ids and ports, and the route list its denoms (`sanitize.TableCell`, `InlineText`) |
| §7.12 gno side | route replacement above, naming its suspect height; settlements of a retired client's sends (`Route.SettleRecords`, `NewSettleRequest` and `NewEthSettleRequest` naming a sequence once per direction, an outbound send and an inbound receive of one sequence together: payments checked against the escrow the liabilities still reserve once the whole batch applies, every queued refund and forged claim it releases counted in any item order; whole remainders, zero for a genuine refund paid in full, forged refunds, each record once; a settlement's refund is paid directly, outside the refund meter and, for a minted denom, outside the supply cap (only the outstanding total's integer capacity is checked), while a refunds hold still defers the decision; a settlement marks the transfer app's send record and leaves the retired client's commitment in the core as it is); a reopening waits for every open record and every record processed in the suspect interval, and runs its deficit acceptance in batches (`ContinueReopen`); `NewRecordLossRequest`; owed refunds reserved; retired client ids final; a retired client takes the authorized app's pending asynchronous acknowledgements |
| R17, §6.7 deployment | a fresh deployment: the transfer proxy's first registration is impl/v1, which serves non-Ethereum clients through impl/v0's logic and puts every Ethereum client under the controls; an Ethereum client carries nothing until `NewEnrollRouteRequest` makes it a route; impl/v0 registers nothing, and the proxy refuses an implementation without the controls once a route exists |
| §7.12 proven outcomes | `transfer.ProveOutcome` reads the destination router's receipt (`ethereum.PacketReceiptCommitment`) and acknowledgement through the replacement client (`core.CounterpartyValue`, which refuses a verifier not Active or retired); an absence counts only at a destination time at or past the packet's timeout; an outcome is final while its verifier stays healthy under the trust generation it was proven in, and void (to be proven again) once the verifier froze, expired, or was recovered, upgraded, migrated or substituted, checked again when the settlement consumes it; a recovered Ethereum client proves nothing from its pre-recovery consensus states; settlement actions must match; action 5 makes a forged receive's claim forged and books what it paid once; a refund paid for a delivered packet is booked only by action 4 |
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
| `InFlight` (open sends' amounts) | checked at every send: bounds every refund owed |
| `QueuedRefunds`, `Returning` | must (≤ `InFlight`) |
| `Owed`, `Withheld`, `Swept` | checked as their sum at every credit (`liabilities`); moves between them must |
| `Outstanding` | checked before every minted payout (a settlement's refund beyond a released reservation included): a sweep payment that would overflow it is refused whole, its entries kept (the decision spent); a claim installment and a queued refund installment are capped to the headroom, the remainder kept; an immediate refund that would not fit is queued (`TestMintedPayoutHeadroom`) |
| `OpenUnrecovered`, `OpenUnresolved` (denom and incident): the outstanding loss balances | checked (`lossFits` admits a loss against `OpenUnrecovered`, which bounds `OpenUnresolved`), batch sums checked per addition; a recovery (a paid recapitalization, a reduction: `recover`) takes off `OpenUnrecovered`, freeing admission capacity, and off `OpenUnresolved` as far as it remains; an accepted deficit (`accept`) takes off `OpenUnresolved` only and frees no admission capacity |
| `Lost`, `Recapitalized`, `Reduced`, `Accepted` (denom and incident): lifetime totals | stat (saturating), never read by a check |
| a settlement's payments, queued refunds and losses; a sweep payment's total | checked per addition |
| `Reserved`, `booked`, unpaid authorizations, `Route.Unrecovered/Unresolved` (the route-wide sums of the outstanding balances), a reopening's accepted total | bound (saturating) |
| `Credited`, `Paid`, `Fees`, `SweepPaid`, `Sent`, `SendFees`, `Refunded` | stat (saturating) |
| a claim's `Paid`/`Reduced`, a record's `Refunded`, a meter's level | bounded by the claim, the record, the ceiling |
| queue and refund sequences, authorization ids, open and pending record counts | grow by one per transaction |
| impl/v1: a send's amount plus the route fee | checked |

### Governed execution never aborts

Every decision ibcgov executes refuses deterministically, spending the
decision, on the failures below that the live state could later clear (by
preflight before crossing, or a refusal returned by the callee). An
implementation installation is the exception: the candidate's constructor
and `OnInstall` run without panic recovery, so a panic there rolls back the
whole execution and a queued decision stays pending. A verifier replacement
is not: its conversion runs on a detached snapshot, a panic in it recovered,
and a converted verifier that fails its checks is refused before anything
is installed, so the decision is spent:

| Decision | Failure conditions refused |
|---|---|
| core/transfer update impl | not registered; the candidate's manifest does not install over the active version (`CheckUpdateImpl`, from the manifest alone, store-free); a transfer implementation without the route controls once a route has them (the controls are never rolled back) |
| core add/remove relayer | listed already / not listed |
| core recover client | unknown, retired, mismatched or wrong-status clients; the light client's own check (`CheckRecoverClient`) |
| core migrate client | unknown, retired or non-Ethereum client; no migrating implementation; the light client's check (`CheckMigrateClient`); for a verifier replacement, a conversion the active implementation does not declare from the client's verifier version to the target, the client not Active or not Ethereum, and, returned by the core, a conversion that panics or a converted verifier of another version, not Active, or at another latest height |
| core approve app | no pending registration; port taken |
| core reject app | no pending registration |
| core pause / pause app / unpause / unpause app | paused already / no app / not paused |
| core/transfer add/remove member | member already / not a member / ibcgov itself |
| transfer block/unblock | blocked already / not blocked |
| route operations (`GovApply`) | every refusal returned, including no controls installed; a sweep payment under a payouts flag, or a settlement paying refunds under a refunds hold, is deferred (stays pending) rather than spent |
| route enrollment | as `GovApply`; the client no longer usable (`checkRouteClient` again at execution: not Active, retired, not Ethereum, no counterparty, a route's already), before either realm changes |
| route replacement | as `GovApply`; the new client unusable; the route's client moved |
| bind governance | bound already; not Active, or not the current client of an enrolled route |
| seats | an address in two seats; nothing to change |
| unpause route | spent under a hold; no flag |
| cancel | not pending |
| Ethereum-bound kinds | channel unbound; envelope too long; past epoch (cancel); the core's send refusals (paused, app paused, client retired, inactive, uncounterparted, latest consensus time past the timeout) |

Tests: z1e, z1f, z1h, z1i, z1j, z2e (ibcgov), z9zj, z9zk (transfer).

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

A denom configuration is refused unless (`DenomConfig.Validate`,
`Route.SetDenom`): the cap floor is positive; the fee floor is positive and
`FeeFloor ≤ Fee ≤ CapFloor/4` (the configured cap floor, not a larger
lock-derived day cap); the refund cap is positive; an `unescrow` denom has
`0 < SendMin ≤ SendMax`, no supply cap and a non-zero lower-case Ethereum
token (`Remote`); a `mint` denom has a positive supply cap, no send limits
and no `Remote` (its base is its token). A denom's accounting never changes,
and its cap floor never goes below the value it was enabled with
(`LaunchCapFloor`).

The rendered route JSON (`routes/<route>`) shows each meter as stored: its
level and time as of its last refill (`meter`, `refund_meter`), not what it
holds now. What a claim could be paid now is `controls.Reader.Meters`
(route, denom, recipient, now, the payouts epoch and its time from
`ibcgov.PayoutsEpoch`, the lock), which refills copies of the bridge and the
recipient meter to now under that epoch.

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
   installments of at least `min(remainder, max(1, RefundCap/24))`.
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
      as on Ethereum, and a settlement whose payments exceed the free escrow
      is refused whole (Ethereum parks the payment instead).
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

- **Vacating seats is immediate** (§7.5 removals), so a decision can remove the
  flagging guardians and end a hold 24 hours later; the day-21 rule only
  governs replacements. A route with unresolved losses stays closed all the
  same.
- **A recapitalization authorized and not paid when a route reopens** is
  revoked: the reopening records the remaining unresolved losses as an
  accepted deficit.
- **The pending asynchronous acknowledgement path of a credit by vote** cannot
  be exercised end to end: the transfer app never answers asynchronously, so
  no transfer packet waits for one. The core side (retired clients taking the
  app's acknowledgement) and the controls side are tested separately.
- **Replacement does no per-denom work**: its candidate check reads the
  core and the registry only. Walks that remain on governed or
  permissionless paths: `ExposureClosed`, checked on every gno-native send
  and every receive (a voucher return checks only the replacement closure),
  walks the route's enabled denoms; settling or rejecting a queued refund
  finds it by walking the denom's refund queue (`unqueue`); the
  recapitalization paths walk only the incident's open authorizations,
  indexed per denom and incident and at most `MaxOpenRecaps` (64):
  authorizing makes two such scans (the open total, then the count against
  the cap), paying one (the total), a reduction one (`revokeConflicting`:
  the total once, then revoking newest first), and an explicit revocation
  goes to its authorization directly; a reopening's blocker check (`reopenBlocker`) loops over the route's retired clients, reading each one's open-record count and counting its records processed in the suspect interval in logarithmic work (an `avl.Node` by processing height), never walking the records. A hold's seat count and a seat's
  removal are constant work (live flag counts per seat, seat generations).
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
  holds need an Ethereum route and are covered by filetests only.
