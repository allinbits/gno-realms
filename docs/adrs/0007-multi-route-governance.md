# ADR 0007: Independent governance per router route

- Status: Accepted, implemented
- Date: 2026-11-17
- Depends on: ADR 0004 (route controls, ibcgov), ADR 0008 (Arc light client,
  allinbits/gno-realms#98)
- Supersedes in part: ADR 0004's one-route scope, its global guardians and
  hold, and its route-less channel API (section 9 lists the rules)

## Context

ADR 0004 scopes ibcgov to **one governance channel and one router route,
ever** ("Scope: one governance channel, one Ethereum route"). `checkOneRoute`
refuses any second enrolment, when it is requested and again when it
executes. A router client of no enrolled route carries no transfers, because
the route controls refuse it. The reason is governance, not transfers: the
counterparty's IBCAdmin replaces, recovers, settles and reopens only the
route it governs over (its kind 10 and its emergency recovery name that
route's client). A second route would therefore have no governed replacement
or recovery path.

With the Arc light client (ADR 0008), gno.land should be able to run an
Ethereum route and an Arc route **at the same time**. They are two different
IBC links, each to its own chain, with its own ICS26 router and IBCAdmin.

The intended rules:

- **Per route, unchanged:** each route works exactly as the one route does
  today. That covers enrolment, the governance channel binding, epochs and
  dispatches, the expected-transition graph, notices, retirement, guardians,
  flags, holds and every builder and its checks.
- **Independent routes:** nothing that happens on one route (a hold, a
  flag, an epoch switch, a dispatch, a seat change, a full graph) changes
  what another route accepts, sends or defers.
- **One decider:** GovDAO governs every route, and before the yield the
  governor does. Guardians and seats may differ per route.

What already supports several routes, and needs no change:

- **Route controls** (`p/aib/ibc/ics20/controls/v0`, transfer
  `impl/controls/v0`): the `Registry` holds routes by route key, with client
  aliases and retired clients per route. Meters, claims, send records, voids,
  losses and escrow are all per route (escrow is keyed by route key).
- **Core:** router-ness is per client (`core.IsRouterClient`). Relaying,
  recovery, migration and retirement are per client. One port `gov`
  serves every client.
- **Counterparty contracts:** each chain deploys its own ICS26 router,
  ICS20 app and IBCAdmin, with its own guardians, its own emergency recovery
  and its own kind 14 latch. Nothing on Ethereum or Arc knows about the other
  chain.

What does not: almost all of ibcgov's governance-channel and guardian state
is package-level, so it implicitly belongs to "the" route:

- **The channel:** `epoch`, `epochs`, `dispatches`, `govIdentity`.
- **The expected-transition graph:** `expected`, `tombstones`, `liveEdges`,
  `awaitingGov`, `approvedLocal`, `proven`, `owned` and `intents`,
  `routerHistory`, `govPruneAfter`, and the retransmit authorizations.
- **The guardians:** `seats`, `seatGen`, `seatFlags`, `genEnds`,
  `pruneAfter`, `holdSince` and `belowSince`.

Today any two guardian seats flagging, on any route, hold every decision.

## Decision

### 1. The route is the unit of governance

Every piece of state listed above moves into one record per enrolled route,
`routeGov`, kept in `routes` beside what the route record holds now (its
key, its identity and its payouts epoch):

| Group | Fields (today's names) |
|---|---|
| Channel | bound or not, `govIdentity`, `epoch`, `epochs`, `dispatches`, retransmit authorizations |
| Expected graph | `expected`, `tombstones`, `liveEdges`, `awaitingGov`, `approvedLocal`, `proven`, `owned`, `intents`, `routerHistory`, `govPruneAfter` |
| Guardians | `seats[SeatCount]`, `seatGen`, `seatFlags`, `flags`, `genEnds`, `pruneAfter`, `holdSince`, `belowSince` |

Each route keeps every bound it has today: 64 graph places, 4 successors per
router client, 64 notice steps, 1024-byte envelopes. Every rule of ADR 0004
"Governance channel" and "Governance retirement of a route's clients: the
one rule" applies within a route, unchanged, with "the epoch client", "the
governance route" and `govRoute` reading that route's record.

What stays global, because it is shared or because it is GovDAO's:

- the governor, `yielded` and `Yield`: one decider for all routes, and one
  yield that hands every route, present and future, to GovDAO at once. A
  route enrolled after the yield is GovDAO's from the start;
- the decision ledger, one numbering of every decision;
- the bridge realm index and the `gov` port registration;
- `pendingAuth`, which is set and consumed within one call and so belongs to
  no route between transactions.

Each record keeps its own flags (section 5), so `PruneFlags(route, n)` walks
one route's flags only, with that route's cursor. Pruning route B, as its
drop requires, never walks route A's flags.

Read-only views: `Routes(from, n)` lists the route keys with a record,
`IsRoute`, `IsProvisionalRoute` and `Incarnation` describe one,
`ClientRoute(client)` names a gno client's route and whether its claim is
permanent, `DecisionRoute(id)` a decision's route ("" for a global one), and
`AnyHeld()` and `GlobalHoldSince()` the global hold.

### 2. Which route a client belongs to

Every gno client ibcgov handles on the gov port belongs to exactly one route.
That means the route's current and replaced clients, and every local client a
transition of the route approves. A new index, `govClients` (gno client →
route key), records it.

**A fresh client is claimed by the decisions that name it.** A client indexed
to no route is not refused. Each decision that names it for a route claims it
when the decision is recorded, and the claim is checked again when the
decision executes:

- an enrolment (`NewEnrollRouteRequest`) claims its client for the new route
  key, which is that client's id;
- a route replacement (`NewReplaceRouteRequest`) claims its new client for
  the route;
- an expectation (`NewEthRouteReplacementRequest`,
  `NewExpectRecoveryRequest`) claims its local client for the route;
- a provisional route record (section 5) claims its client when it is
  created, permanently, until a drop releases it;
- a counterparty client registration (`NewEthClientRequest`, op 1: IBCAdmin
  registers a router client whose counterparty is a gno client) claims that
  gno client for the route. It now also requires the gno client to
  authenticate the route's identity (`ClientRouteIdentity`), when built and
  when recorded. Today it checks only that the client exists and names the
  right counterparty, and that is not enough with several routes: route A
  could pair its counterparty with a client that route B later claims.

**A claim is held by its decisions.** A claim is tentative while only pending
decisions hold it, and it counts its owning decisions, like an intent's
owners (ADR 0004). It becomes permanent when one of them applies. It is
released when the last owning decision is refused, spent or cancelled
without any of them applying. A client claimed by another route, tentatively
or permanently, is refused when a decision naming it is recorded and again
when it executes.

So in the duplicate-enrolment race (two enrolments of one identity, section
4), the losing enrolment is spent and its claim released. Its client, which
is healthy and authenticates the winning route's identity, can then be
claimed by the winning route: as its replacement, or as a local client of
one of its transitions. A permanent claim is never released: a gno client
created for one counterparty chain is never honestly reused on another
route. This cannot happen honestly: a local client must authenticate its
route's identity (`checkLocal`), and two enrolled routes never share an
identity (section 4). The index makes the rule explicit and the lookup O(log).

The packet callbacks resolve the route from the client:

- `OnRecvPacket` (an epoch notice) from the destination client;
- `OnAcknowledgementPacket` and `OnTimeoutPacket` from the source client;
- `OnSendPacket` from the authorization.

A client of no route is refused, as an unknown client is today.

**Router client ids are not unique across routes.** Router client ids are
the counterparty's (`client-0`, `client-1`, …), so Ethereum and Arc can both
have a `client-0`. They are never resolved to a route. Every builder that
takes one also takes the route explicitly (section 7). `checkRouterClient`
and its helpers (`epochRouterClient`, `routeRouterClients`,
`knownRouterClients`, `routerHistory`) read only that route's record. Only
gno client ids, which the core keeps unique, go through `govClients`.

### 3. Wire format: unchanged

The envelope (`version ‖ epoch ‖ seq ‖ kind ‖ params`) and the epoch notice
carry no route id, and need none.

- **IBC keeps routes apart.** A packet sent over route A's client is
  committed to A's counterparty client. A's chain verifies it, and A's
  IBCAdmin receives it. A notice arrives over the local client its route
  approved, and section 2 maps that client to exactly one route.
- **Numbering is per route.** Each route numbers its own epochs and seqs from
  1. Two routes can produce byte-identical envelopes, and that is harmless:
  each is accepted only over its own route's client.
- **No contract changes.** Ethereum and Arc each deploy their own IBCAdmin.
  gno-eth-ibc changes nothing, and its `gov-vectors.json` checks hold per
  route.

### 4. Enrolment: one route per identity, any number of identities

`checkOneRoute` becomes `checkChainFree`: **one route per counterparty
chain**. An enrolment is refused when its client's chain is already an
enrolled or provisional route's chain, whatever its router. The chain is the
part of the route identity that names the chain, not the deployment:

- for Ethereum: chain id and genesis validators root;
- for Arc: chain id and validator registry.

Each verifier exposes it beside `RouteIdentity` (a new `ChainIdentity`, read
through `core`). The route's full identity, including the router and
commitments slot, is still recorded and checked as today
(`checkIdentity`, `checkLocal`).

As today, the check runs when the decision is requested and again when it
executes, so of two requested together for one identity only the first
applies. A second deployment on the same chain, with another router and
IBCAdmin, would need its own route on that chain, which this design does not
support (Alternatives).

The number of routes has no fixed cap. Each route, provisional or enrolled,
exists only through a 7-day GovDAO decision (an enrolment, or the seat change
that creates a provisional record), so GovDAO's vote is the bound. No path
loops over every route: the global-decision hold check reads three numbers
(section 6); ibcgov's Render and the transfer app's home page list 20 routes
a page, and the transfer app's `routes` JSON pages them like the other JSON
pages (100 a page, with their cursor); and the transfer proxy's controls-continuity check asks whether any
route exists (`Reader.HasRoutes`), in constant work.

The per-route rules of ADR 0004 hold for each route separately:

- `NewBindGovernanceRequest(route, clientID)` binds the route's channel to
  `clientID`, its original and current client (`checkBindClient`).
- No replacement precedes that route's binding (`checkBoundForReplace`).
- Value moves only after that route's launch is proven. Its first denom
  enablement waits for that route's IBCAdmin to record gno.land's first
  decision (`lastSeq() >= 1` at that route's epoch 1).

Binding Arc's channel needs no Ethereum binding, and the reverse. A route may
be enrolled and bound while another is replaced, recovered, held or closed.

### 5. Guardians per route

**A route record exists before its enrolment.** Today the seats exist before
any route is enrolled, so guardians can flag a client from the start. To keep
that, a route record can be created **provisionally**, by
`NewSetSeatsRequest(route, changes)` naming a route key no route uses yet.
The key is the id of an existing client, the one the route will be enrolled
with. A provisional record:

- **reserves its client's chain** (section 4): no other route, enrolled or
  provisional, may be on that chain. An enrolment of that chain must name
  the record's client and so adopt the record. An enrolment naming another
  client of that chain is refused, so it cannot start the chain with vacant
  seats and bypass its guardians;
- holds seats, flags and a hold, and no channel or graph;
- has a hold that defers its own decisions (its enrolment and its seat
  changes) and, like any route's hold, every global decision (up to the
  global decision's day-21 deadline, section 6);
- is adopted with its seats, flags and seat generations by the enrolment of
  its key.

`NewDropRouteRequest(route)` removes a provisional record, for instance when
its client failed before enrolment and the chain must start again from
another client. It is refused, when built and when it executes, unless:

- every seat is vacant. Seats leave through ordinary seat decisions, 7 days
  each, so a drop cannot remove a guardian faster than a seat change can;
- no hold stands, its 24-hour linger included;
- no flag entry of the route remains, stale ones included, and no `genEnds`
  record. `PruneFlags` must have removed them first;
- no **other pending** decision names this incarnation of the route. Applied,
  spent and cancelled decisions in the ledger do not count, and neither
  does the drop itself. Each incarnation keeps a count of its pending
  decisions, so the check reads one number, not the ledger. The count goes
  up when a decision is recorded, the decisions a builder records for it
  (such as an expectation) included, and down when one applies, is spent or
  is cancelled. The count is kept per route key and incarnation, not on the
  record, so a decision recorded before the record exists (a second seat
  change creating it, an enrolment) counts too.

When a provisional record is created it permanently claims its client
(section 2). Until enrolment, decisions about that client (recovery,
migration, verifier replacement) are therefore scoped to the provisional
route and held by its guardians. A drop releases the claim, and only a drop
does.

**Each record has an incarnation number.** Its flags and generation records
live in the record itself, so a route key used again after a drop starts a
new incarnation with none: nothing left from the old one, a flag or a
generation end, can count toward the new record's seats. **Requests are bound to the
incarnation too.** A route-scoped Request records the incarnation it was
built against, and is refused when recorded or executed against another.
A GovDAO proposal built before a drop therefore cannot change the
re-created route's seats. An enrolment with no
provisional record creates the record, with vacant seats.

Each route has its own six seats, with the same roles as today:

- seats 0–3 are the guardians (2 and 3 the outsiders');
- seats 4–5 are the operator's watch keys.

The seat rules are those of ADR 0004 and ADR pr6375 §7.4, applied per route:

- `NewSetSeatsRequest(route, changes)` changes one route's seats: 7 days,
  landing through that route's hold from day 21. A new route's seats start
  vacant, as the first route's do today.
- `SetFlag(route, target, fn, keys)` and `ClearFlag(route, target, fn)`
  require a seat **of that route**. One key may hold seats on several routes; its seats are
  independent. A flag it sets on route A counts toward A's hold only, and a
  seat change on one route leaves its seats on the others as they are.
- **Holds are per route.** Two guardian seats of route R with a live flag
  make R's hold, which lingers 24 hours after fewer than two flag. R's hold
  defers R's decisions and spends R's unpause decisions. It never touches
  another route's.
- `seatFlags` and `seatGen` count per route, so a flag on route A never
  counts toward route B's hold. Today a flag on any route counts toward the
  single hold.
- **Flags belong to the route whose seat set them.** Each record keeps its
  own flags, keyed `target|fn|seat`, `target` the route key or the key of a
  candidate client flagged before it joins (below). Their seat
  generations, counts and hold are that route's. The same seat number on two
  routes, flagging the same candidate, makes two flags that never collide.
  The readers are `Flagged(route, fn)` (the route's flags on its own key,
  what the transfer app asks) and `Flags(route, target)` (`target` "" for
  the route itself). `NewUnpauseRouteRequest(route, target, fns)` clears a
  route's flags of `fns` on a target, and `PruneFlags(route, n)` walks only
  that route's flags.
- **Flags on candidates, before enrolment or replacement.** Today a guardian
  may flag a client that is not yet a route's: an unenrolled client, or a
  replacement candidate. `foldFlags` then moves those flags onto the route
  key when the client joins the route. Per route, such a flag is set by a
  seat of the route the candidate is meant for, `SetFlag(route, target, fn,
  keys)`, with `target` the candidate's key. `foldFlags` moves an owner's
  flags from the candidate's key to its own route key when the candidate
  joins that owner's route, and only then. A candidate that joins another
  route takes none of them: they are the first route's seats' and seat
  generations'. They stay there, still counting toward the first route's
  hold, until a seat clears them, an unpause clears them or a prune drops
  them. Such a candidate's id now names the other route, so a route's
  `ClearFlag`, `Flags` and unpause read a target under its own id while the
  route holds entries there, and its route key otherwise. Flagging a
  candidate does not claim it (section 2), but a client another route
  claims, tentatively or for good, cannot be flagged.

Ethereum-side seats are per chain already: each IBCAdmin has its own, set by
`NewEthSeatsRequest`, now dispatched to the named route.

### 6. Every decision has a scope

A decision is either **route-scoped** (it names one route) or **global**.

**Route-scoped** decisions: every builder that names a route or a client of
one.

- the `routes.gno` builders;
- every Ethereum-bound kind, routed by its client;
- the graph builders (expect, remove, purge, retransmit);
- seats and route unpauses;
- `NewRecoverClientRequest`, `NewMigrateClientRequest` and
  `NewReplaceVerifierRequest` on a client that belongs to a route, of any
  client type (section 9, client migrations).

A route-scoped decision is deferred only by its route's hold, and spent only
by its route's hold if it is an unpause. A payout decision is also deferred
by its route's flags, as today (`deferredBy`).

Holds keep today's reach, and only their owner changes:

- **Queued gno-side decisions** (7 days) are deferred by a hold.
- **Gno-side route unpauses** are spent by their route's hold. Global
  unpauses are deferred instead (below).
- **Ethereum-bound decisions are dispatched at once,** as today. Their delay,
  flags and holds are the counterparty IBCAdmin's, so no gno-side hold
  touches them.
- **Immediate decisions** stay immediate: tightenings such as a void, a
  refusal or a route pause; cancellations; retransmit authorizations;
  expectation removals.

**Global** decisions change the shared core or transfer app:

- core pause and unpause, app approve, reject, pause and unpause;
- relayers, authority members, `UpdateImpl` of either proxy;
- transfer block and unblock;
- a recovery, migration or verifier replacement of a gno client claimed by no
  route: a Tendermint client, or a router client not yet enrolled or
  claimed. No route's guardians own such a client, so the global rule
  applies, and any route's hold defers it. Once the client is claimed, the
  same decision is route-scoped. A decision recorded as global whose client
  is claimed before it executes is spent ("X belongs to route R: a decision
  of no route cannot name a route's client"): it was approved under the
  wrong hold rule. Such a decision cannot name a route's client from the
  start either: a recovery of a client of no route whose substitute is a
  route's client is refused.

A global loosening reaches every route, so **any route's hold defers it**.
Each route's guardians can therefore delay what affects their route; none can
veto.

**A global decision's delay is capped, as a seat change's is.** Holds on
several routes could otherwise be chained: route A holds to day 21, GovDAO
vacates A's seats, route B's guardians start a hold the same day, and the
delay restarts, about 21 days for each route. So a global decision lands
through holds from day 21 of the **global hold** that first deferred it once
it was due, its anchor, whatever holds stand by then, on any route. The
anchor is recorded at that first deferral and never moves, exactly as a seat
change's (ADR 0004, ADR pr6375 §7.4). A global decision therefore waits at
most its 7 days plus 21, however many routes there are and however their
holds are staggered.

A **global hold** is a period in which some route holds without a gap. It
starts when a route's hold starts while no route holds or lingers, at
`globalHeldSince`, and lasts while any route holds or lingers. A hold that
starts on B while A's still stands or lingers continues A's global hold and
keeps its start.

**A global unpause is deferred, never spent.** A route's hold spends that
route's unpauses, as today, because the route's own guardians answer for its
state. A global unpause reopens the core or the transfer app for every route,
and spending it would let one route's guardians undo it, so that GovDAO has to
record it again and wait 7 more days, each time. It is deferred like any other
global decision and lands from day 21 of its anchor.

**The global check is constant work, however many routes exist.** ibcgov keeps
three numbers beside the per-route hold state:

- `routesFlagging`: how many routes have two or more seats flagging. A route's
  `updateHold` raises it when the route reaches two flagging seats and lowers
  it when the route falls below two. Both happen only on flag events.
- `lingerEnd`: the latest end of any route's 24-hour linger. When a route falls
  below two flagging seats at t, it is raised to t + 24 hours if that is later.
  It is never lowered.
- `globalHeldSince`: the start of the current global hold. When a route
  reaches two flagging seats at t while `routesFlagging` is 0 and
  `t >= lingerEnd`, it is set to t; otherwise it is left as it is.

Some route is held at t exactly when `routesFlagging > 0` or `t < lingerEnd`.
If a route is lingering, `lingerEnd` is at or past its own end, so the check
holds. Conversely, `lingerEnd` was set by a route that fell below two seats at
`lingerEnd` - 24 hours. A linger ends only by time, so that route is still
lingering, or it reached two seats again (and is counted, or set a later
`lingerEnd`). A route cannot be dropped while it holds or lingers (section 5).
The deferral and spent messages for a global decision name no route, since
finding one would loop; Render shows which routes hold.

A builder that names a gno client claimed by a route other than the one it
names is refused, both when recorded and when executed.

### 7. API

The realm is not deployed, so its exported surface can change.

**Every route-scoped entry point takes the route key explicitly,** as its
first argument after `cur`. A route is never inferred from a router client
id (section 2). The route arguments added:

- the channel: `Redispatch(route, e, seq)`, `Rebind(route, e, from, to)`
  (ADR 0004, "Burned numbers and Rebind": a route's burned numbers, those
  acknowledged cancelled, status 6, that no kind 1 of the route's own
  channel named, are told apart per route and epoch, and rebound to that
  route's next numbers only), `NewRetransmitRequest(route, e, seq)`;
- every Ethereum-bound kind: `NewEthCancelRequest`, `NewEthUnpauseRequest`
  (whose object 2 takes no client), `NewEthSeatsRequest`,
  `NewEthLimitsRequest`, `NewEthVoucherRequest`, `NewEthClientRequest`,
  `NewEthUpgradeRequest`, `NewEthRoleRequest`, `NewEthHandOverRequest`,
  `NewEthRouteReplacementRequest`, `NewEthRouteSettingsRequest`,
  `NewEthSettleRequest`, `NewEthReopenRequest`,
  `NewEthDisableRecoveryRequest`;
- the graph builders: `NewExpectRecoveryRequest`,
  `NewRemoveExpectationRequest`, `NewPurgeTombstoneRequest`;
- `NewBindGovernanceRequest(route, clientID)`;
- channel readers: `Epoch(route)`, `EpochClient(route)`, `LastSeq(route, e)`,
  `DispatchBody/State/Transport(route, e, seq)`;
- graph readers and pruning: `Tombstones(route)`,
  `AwaitingGovRetirement(route)`, `PruneGovRetirements(route, n)`;
- guardian readers: `Held(route)`, `HoldSince(route)`, `Seat(route, n)`,
  `SeatOf(route, a)`, `Flags(route, target)`;
- guardian entry points and decisions: `SetFlag(route, target, fn, keys)`,
  `ClearFlag(route, target, fn)`, `PruneFlags(route, n)`,
  `NewSetSeatsRequest(route, changes)`, `NewUnpauseRouteRequest(route,
  target, fns)`, `NewDropRouteRequest(route)`.

The `routes.gno` builders already take the route. `ApplyEpochNotice(e, client,
path)` keeps its signature: its `client` is a gno client, resolved through
`govClients`, and every step of `path` must belong to the same route.

**Render and events name the route.**

- `Render` shows one section per route: identity, epoch, seats, flags, hold
  and graph. The route list is paged (`?from=` the next route key), like the
  decision ledger.
- The dispatch page becomes `dispatch/<route>/<e>/<seq>`, since `(e, seq)`
  repeats across routes. It adds `burned`, `rebound_to` and `rebound_from`
  (ADR 0004, "Burned numbers and Rebind") after the existing fields.
- Every governance event carries a `route` attribute: `GovPacketSent`,
  `GovAck`, `GovTimeout`, `GovNotice`, `GovEpoch`, `GovExpect`, `GovIntent`,
  `GovUnexpect`, `GovTombstone`, `GovPurge`, `GovRebind`, `Flag`, `Unflag`, `FlagsMoved`,
  `Hold`, `HoldEnding`, `SeatSet` and `SeatFlagsEnded`.
- A route-scoped `Decision` event and the decision's description name the
  route, so monitors and voters can tell the routes apart.

### 8. What changes outside ibcgov, and what does not

Changes outside ibcgov, all before deployment (the proxies are not deployed
yet, ADR 0004):

- **Light clients.** Each router verifier exposes `ChainIdentity()` beside
  `RouteIdentity()`: Ethereum's chain id and genesis validators root, and
  Arc's chain id and registry (added with the Arc light client,
  allinbits/gno-realms#98: a verifier naming no chain identity is refused a
  route). The core reads it with a new accessor, `core.ClientChainIdentity`.
- **Route controls registry and the transfer proxy.** `HasRoutes` and
  `RoutesFrom` page the routes; `RoutesJSON(from)` is a page like the other
  JSON pages, no longer one array of every route; the transfer proxy's
  `controlsContinuity` reads `HasRoutes` instead of counting the routes.
- **Route controls / transfer `impl/controls/v0`.** The send path refuses a
  voucher's GRC20 on any route (a voucher leaves only by its `ibc/` denom,
  burnt on its own route), and the denom operation of `GovApply` refuses an
  unescrowed denom in the voucher namespace and a minted denom allocated to
  another route (section "Consequences", foreign vouchers). The transfer
  realm exports `DenomPath` and `IsVoucherKey` for ibcgov's checks.

Unchanged:

- **Core and transfer proxies:** one ibcgov remains their governance
  (`IBCGovPath`), now governing every route. No store change; the transfer
  proxy's only change is the constant-work continuity check above.
- **The core implementation**, apart from the accessor above.
- **The envelope, the epoch notice, the acknowledgement format and every
  gno-eth-ibc contract.** (A later change, independent of multi-route, adds
  app status 6, cancelled, to the acknowledgement's status byte: ADR 0004,
  "Burned numbers and Rebind".)
- **ADR pr6375's rules within a route.** Its "one channel" becomes "one
  channel per route", and the global ADR gains a paragraph saying so.

### 9. Changes to ADR 0004

This ADR supersedes these parts of ADR 0004, which carries a "Superseded in
part by ADR 0007" note. Everything else in ADR 0004 holds per
route.

- **Scope: one governance channel, one Ethereum route.** Replaced by one
  channel per enrolled route, at most one route per chain, and no fixed number
  of routes (section 4). `checkOneRoute` and z9zzs's "only the first of two
  enrolments" apply per identity.
- **Storage, ibcgov.** The channel, graph and guardian fields move into each
  route's record (section 1), and `govClients` is added (section 2).
- **Authorities.** `SetFlag` and `ClearFlag` need a seat of the named route.
  Ethereum-bound builders and channel entry points take the route.
- **Guardians and holds** (and ADR pr6375 §7.4 as ADR 0004 applies it). Seats,
  flags, seat generations and holds are per route. A hold defers its route's
  queued decisions and every global one, a global decision at most to day 21
  of the global hold that first deferred it, and a global unpause is deferred
  rather than spent (section 6).
- **Governance channel API and Render.** Route-qualified, as listed in
  section 7.
- **Denoms.** A route may configure only its own vouchers and non-voucher
  denoms (Consequences, foreign vouchers), and the send path enforces it.
- **Client migrations, any client type.** `NewMigrateClientRequest` no
  longer refuses a client that is not Ethereum or a migration it does not
  know: ibcgov is immutable, so it forwards any migration (a name of 1 to 64
  characters of `a-z`, `0-9` and `-`, with hex params) to the core, and the
  active core implementation decides (`core.CheckMigrateClient` when the
  decision executes: a migration it does not support spends it, z1c). A migration replaces a client's verifier in place: the client
  keeps its id and the type it was created with, so moving a route to a
  client of another type is a route replacement, never a migration. The
  two Ethereum migrations keep their readable decision text; any other is
  written as its name and params. An Arc or Tendermint verifier conversion
  then needs only a core implementation that declares it, installed by a
  governed `UpdateImpl`, and the migration is a decision of its client's
  route, 7 days, as Ethereum's are.

## Consequences

- One ibcgov governs several routes, each as independently as if it were the
  only one. Losing a route (a forged client, a stalled Arc client, a full
  graph, a frozen governance client) affects only that route. Global
  decisions are the exception, and any route's hold can delay them.
- The guardian work per route is the same as today's. Operators run a watch
  per route; the monitor must read ibcgov's state per route.
- The ibcgov code changes widely but mechanically: the state moves into
  `routeGov` and the functions take it. The risk is a missed global read.
  The tests must show each rule is per route (below), not only that one
  route still works.
- Shared things remain shared, because they are the core's and transfer
  app's:
  - core and app pause;
  - the transfer implementation;
  - the bridge realm index;
  - the relayer whitelist. It gates client creation for every client
    (`core.CreateClient` calls `ensureAuthorizedRelayer`), so every route's
    bootstrap and replacement clients depend on it. It also gates relaying
    for non-router clients. Relaying for existing router clients is public.
- **A voucher of one route is never a denom of another.** Today's checks do
  not ensure it. A voucher's GRC20 registry key goes through the ordinary
  GRC20 send path, and could be configured on route B as an `unescrow`
  denom, tying B's backing to A's. That would be a multi-hop the controls
  do not account. Two rules close it:
  - **At configuration.** `NewSetDenomRequest(route, denom, …)` refuses any
    denom in the voucher namespace, allocated or not, other than the
    route's own vouchers. That covers IBC denoms (`ibc/…`) and the GRC20
    registry keys and aliases the transfer app gives vouchers. A route
    therefore cannot pre-enable a voucher key that another route will be
    allocated later. The check runs when the decision is built, recorded and
    executed.
  - **A voucher is named by its trace, not its hash.** A raw `ibc/<hash>`
    cannot be attributed to a route before its first receive, because its
    trace is stored only then, and that receive already needs the denom
    configured. So a new voucher denom is configured by its base: the
    counterparty token, which the route's client turns into the voucher's
    trace. A raw `ibc/<hash>` is accepted only for a voucher already
    allocated to this route. This restricts today's API, and tests pin it.
  - **At use.** The route controls' send path refuses a voucher's GRC20
    registry key on every route, whatever the denom configuration says: a
    voucher returns only by its `ibc/` denom over the route it came from,
    which the send path already enforces.

  Tests cover both forms, a key enabled before its voucher exists, and a
  voucher created while a configuring decision is pending.

## Tests (implementation plan)

- **Run the whole suite against one route** (every existing ibcgov,
  transfer and core filetest) with the new API. One route must behave
  exactly as today.
- **New two-route filetests,** with the Ethereum fixture client and the Arc
  fixture client side by side:
  - **Enrolment:** both enrol and bind independently, and a second enrolment
    of an already enrolled identity is refused.
  - **Hold:** route A's hold defers A's decisions only. B's decisions
    execute, and a global decision is deferred.
  - **Unpause:** a route unpause on A is spent by A's hold, not by B's.
  - **Seats:** a seat of A cannot flag B. A key holding seats on both routes
    has independent flags.
  - **Numbering:** both routes dispatch epoch 1 seq 1, and each is
    authorized, acknowledged and redispatched over its own client only.
  - **Notices:** an epoch notice over A's local client moves A's epoch and
    never B's. A notice whose path names a client of the other route is
    refused.
  - **Graph:** route A's graph at its 64-place cap does not refuse
    B's expectations.
  - **Retirement:** a route replacement and governance retirement on A leave
    B's clients open.
  - **Client index:** a client indexed to A is refused as B's local client.
  - **Global hold check:** route A's hold ends and lingers while route B's
    starts and clears. A global decision is deferred until the later linger
    ends, and not after it. A third route enrolled changes neither count.
  - **Global deadline:** A holds, a global decision is deferred, A's seats
    are vacated on day 21 while B starts a hold on day 20: the global
    decision lands on day 21 of A's hold, not of B's. A global unpause
    deferred by a hold lands on its deadline and is not spent; a route
    unpause is still spent by its route's hold.
  - **Claims:** a counterparty registration (`NewEthClientRequest` op 1) on A
    naming a client of B, or one that authenticates another identity, is
    refused. In the duplicate-enrolment race, the losing enrolment's client
    is released and then claimed as the winner's replacement.
  - **Provisional routes:** seats set before enrolment flag a candidate and
    the enrolment adopts them. An enrolment of the same chain naming another
    client is refused. A drop is refused while a seat is occupied, a hold
    lingers or a stale flag entry remains, and a re-created key's new
    incarnation does not count the old flags.
  - **One chain:** a second route to an enrolled chain with another router
    is refused.
  - **Flag keys:** seat 0 of A and seat 0 of B flag the same candidate; each
    flag counts only toward its own route's hold, and only A's folds when
    the candidate joins A.
  - **Pruning:** many stale flags on A do not delay pruning B or B's drop.
  - **Pending count:** a drop is refused while one decision of the
    incarnation is pending, and allowed once it applies, is spent or is
    cancelled.
  - **Foreign vouchers:** A's voucher, as an IBC denom and as a GRC20
    registry key, is refused as a denom of B, including when the voucher
    is created while the decision is pending.
- **Envelope vectors:** gno-eth-ibc's vectors checked per route (z2b, z2c,
  z2e, z2j against both routes' envelopes).

## Alternatives considered

- **One ibcgov instance per route** (ADR 0004 mentions it). The core and
  transfer proxies accept governance from one realm (`IBCGovPath`), so this
  needs proxy changes before deployment or a router realm. It also
  duplicates the governor, the yield and GovDAO wiring, and spreads global
  decisions over several ledgers. Rejected: one ibcgov with route-scoped
  state gives the same independence with none of that.
- **Shared guardians, route-scoped flags** (today's model with a second
  route). This does not meet the goal: route A's guardians could hold route
  B, and B could not have its own guardians.
- **A route id in the envelope.** This would change the wire format on both
  chains for a separation IBC's client binding already gives.
- **Several routes to one chain** (two deployments, with their own routers
  and IBCAdmins, on one chain). Each would need its own route and channel,
  and the chain's guardians and denoms split between them. Nothing needs it
  now; section 4 refuses it by chain identity.
- **A governor and yield per route.** A route enrolled after the yield could
  then launch under a governor again, which contradicts "GovDAO is always
  GovDAO". Rejected: one governor, one yield.
- **Distinct guardian keys per route** (a key refused a seat on a second
  route). Nothing on chain ties a key to a person, so the rule would not keep
  the guardians distinct people, and it would stop an operator trusted on
  both chains from serving both. Rejected: a key may hold seats on several
  routes, each seat independent.
- **A separate global guardian set**, whose hold alone defers global
  decisions. Who can delay a core change would then be one explicit group,
  at the cost of a third set of seats, and a route's guardians could no
  longer hold a change that harms only their route. Rejected: any route's
  hold defers a global decision, capped at day 21 of the global hold that
  first deferred it, which bounds the delay without another set.
- **A fixed cap on routes** (4 was first proposed), to bound loops over
  routes. The hold counts above remove the only loop on an execution path,
  and every route already needs a GovDAO vote, so a cap would only make a
  fifth chain wait for an upgrade.
