# r/aib/ibc

Because most of the functions in this realm take complex args, it is required
to call them using `MsgRun` (`maketx run` with the CLI) instead of the more
commonly used `MsgCall`.

Here is an exemple of the command:

```
$ gnokey maketx run -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid "dev" -remote "tcp://127.0.0.1:26657" \
    ADDRESS run.gno
```

`run.gno` content depends on the called function, see the following sections
for examples.

## RegisterApp

Applications register themselves with `core.RegisterApp(cross(cur), portID, app)`
from their own realm (a user cannot call it), each port at most once, and a port
is never freed.

- A registration from this project's namespace, `gno.land/r/aib/...`, is active
  immediately: only the owner of the `aib` namespace can deploy there.
- A registration from any other realm is recorded as **pending** and routes
  nothing until an ibcgov decision activates it with
  `ApproveApp(portID, pkgPath)`, or the authority drops it with
  `RejectApp(portID, pkgPath)` (GovDAO constructor
  `NewRejectAppProposalRequest`, see the Authority section). Pending
  registrations claim no port, so they can
  neither block a trusted app nor be approved once the port is taken.
  `IsAppPending(portID, pkgPath)` and `/r/aib/ibc/core:apps/pending` report them;
  the listing shows only the first 100 pending registrations, with no
  pagination, and the full count apart, so a registration missing from it
  is not shown absent: ask `IsAppPending(portID, pkgPath)` for a particular
  one.

Emitted events: `app_registered`, `app_registration_pending`, `app_approved`,
`app_rejected`, with `port` and `pkg_path` attributes.

## CreateClient

See [`zz_create_client_example_filetest.gno`](./filetests/zz_create_client_example_filetest.gno)

Emitted event:
```json
{
  "type": "create_client",
  "attrs": [
    {
      "key": "client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    },
    {
      "key": "consensus_heights",
      "value": "2/2"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## RegisterCounterparty

`RegisterCounterparty(clientID, merklePrefix, counterpartyClientID)` must be
signed by the transaction's origin signer that created the client (its
creator), for any client type: the public relaying of Ethereum clients does
not extend to it. It is write-once: once a counterparty is registered, a
second registration is refused. An Ethereum client's counterparty is the
router's client id with eureka's single empty merkle prefix.

See [`zz_register_counterparty_example_filetest.gno`](./filetests/zz_register_counterparty_example_filetest.gno)

## UpdateClient

See [`zz_update_client_example_filetest.gno`](./filetests/zz_update_client_example_filetest.gno)

Emitted event:
```json
{
  "type": "update_client",
  "attrs": [
    {
      "key": "client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    },
    {
      "key": "consensus_heights",
      "value": "2/5"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## Packet limits

The core checks these on every client's packets, the same on send and on
receive (`types.Packet.ValidateBasic`; on an Ethereum client's packets
`types.Packet.ValidateBasicRouter`, which differs only in the client ids):

| Field | Limit |
|---|---|
| payloads | exactly one (see SendPacket) |
| payload data | at most `types.MaximumPayloadsSize`, 262,144 bytes (256 KiB), counted as the sum of `len(Payload.Value)`: the application's encoded packet data only. The ports, version, encoding, client ids and timeout are not counted, nor is the message carrying the packet (its proofs, or the `ethrelay` wire argument) |
| payload value | not empty |
| source and destination port | 2 to 128 characters of `a-z A-Z 0-9 . _ + - # [ ] < >` (no `/`) |
| payload version and encoding | not blank; anything else is the application's to check (transfer: `ics20-1`, and `application/x-protobuf` or `application/x-solidity-abi`) |
| source and destination client id | 4 to 64 characters of the same alphabet. On an Ethereum client's packets either may instead be an ICS26 router client id: `client-N` (N a decimal uint64 of at most 20 digits, no leading zero) or a custom id of 4 to 128 characters of that alphabet, not starting with `client-` or `channel-`. `SendPacket` also checks its source client against the first rule before it builds the packet |
| sequence | not 0 |
| timeout timestamp | not 0 (Unix seconds). On send: after the current block time, at most 24 hours after it (`maxTimeoutDelta`), and after the sending client's latest consensus timestamp. On receive: refused when the current block time is at or after the packet's timeout timestamp |

A packet over a limit is never committed or received. On send, `SendPacket`
panics and the whole transaction aborts: nothing is escrowed or burned and no
sequence is used. On receive, `RecvPacket` refuses the message before it
verifies a proof, writes a receipt or calls the application, on every route,
Ethereum's included. This is a core refusal, not an application error
acknowledgement: no receipt and no acknowledgement are written, so the
packet stays pending at its source until its timeout, when the source
refunds it (a timeout proves the receipt absent).

## SendPacket

See [`zz_send_packet_example_filetest.gno`](./filetests/zz_send_packet_example_filetest.gno)

A packet must carry **exactly one** payload; `SendPacket` and `RecvPacket` both
reject any other count. The restriction matches ibc-go and keeps `RecvPacket`
atomic: its callback loop stops at the first failing payload without reverting
the ones that already succeeded, so several payloads could commit a partial
state change while the counterparty refunds the whole packet.

Emitted event:
```json
[
  {
    "type": "send_packet",
    "attrs": [
      {
        "key": "packet_source_client",
        "value": "07-tendermint-1"
      },
      {
        "key": "packet_dest_client",
        "value": "counter-party-id"
      },
      {
        "key": "packet_sequence",
        "value": "1"
      },
      {
        "key": "packet_timeout_timestamp",
        "value": "1234571490"
      },
      {
        "key": "encoded_packet_hex",
        "value": "0801120f30372d74656e6465726d696e742d311a10636f756e7465722d70617274792d696420e2a1d8cc042a3f0a12676e6f2e6c616e645f725f69626361707031120f64657374696e6174696f6e506f72741a02763122106170706c69636174696f6e2f6a736f6e2a027b7d"
      }
    ],
    "pkg_path": "gno.land/r/aib/ibc/core"
  },
]
```

## WriteAcknowledgement

For the standard synchronous flow, `RecvPacket` writes the application
acknowledgement itself. An application may instead return
`PacketStatus_Async` from `OnRecvPacket`, in which case the ack is deferred
until the application calls `WriteAcknowledgement` later (typically from a
subsequent `OnAcknowledgementPacket` or `OnTimeoutPacket` callback while
forwarding the parent packet). Only the realm whose `OnRecvPacket` returned
async is authorized to write the ack.

See [`z10a_async_ack_filetest.gno`](./filetests/z10a_async_ack_filetest.gno) for the
full A → B → C forward-and-ack call graph.

Emitted event:
```json
{
  "type": "write_acknowledgement",
  "attrs": [
    {
      "key": "packet_source_client",
      "value": "07-tendermint-42"
    },
    {
      "key": "packet_dest_client",
      "value": "07-tendermint-1"
    },
    {
      "key": "packet_sequence",
      "value": "1"
    },
    {
      "key": "packet_timeout_timestamp",
      "value": "1234571490"
    },
    {
      "key": "encoded_packet_hex",
      "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3120e2a1d8cc042a280a056170704944120561707049441a02763122106170706c69636174696f6e2f6a736f6e2a027b7d"
    },
    {
      "key": "encoded_acknowledgement_hex",
      "value": "0a0101"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## Acknowledgement

See [`zz_acknowledgement_example_filetest.gno`](./filetests/zz_acknowledgement_example_filetest.gno)

Emitted event:
```json
[
  {
    "type": "acknowledge_packet",
    "attrs": [
      {
        "key": "packet_source_client",
        "value": "07-tendermint-1"
      },
      {
        "key": "packet_dest_client",
        "value": "07-tendermint-42"
      },
      {
        "key": "packet_sequence",
        "value": "1"
      },
      {
        "key": "packet_timeout_timestamp",
        "value": "1234571490"
      },
      {
        "key": "encoded_packet_hex",
        "value": "0801120f30372d74656e6465726d696e742d311a1030372d74656e6465726d696e742d343220e2a1d8cc042a300a03617070120f64657374696e6174696f6e506f72741a02763122106170706c69636174696f6e2f6a736f6e2a027b7d"
      }
    ],
    "pkg_path": "gno.land/r/aib/ibc/core"
  }
]
```

## RecoverClient

See [`zz_recover_client_example_filetest.gno`](./filetests/zz_recover_client_example_filetest.gno)

See [`recover-client.md`](./recover-client.md) for the end-to-end flow and
which parameters a Tendermint recovery can adjust.

Recovery is a governed decision (7 days). The subject must be Frozen or
Expired, the substitute Active, the two of the same client type, and neither
retired. For an Ethereum client (`ethereum.CheckRecovery`) the substitute is
read through its `Ethereum()` state, so it may be the v0 verifier or a
verifier version that wraps it (as after a verifier replacement), and so may
the subject; a verifier type without that state needs recovery support of
its own. The substitute must track the same chain and router: the same chain id, genesis validators root,
genesis time and slot, genesis fork and every fork active at the subject's
latest slot, sync committee size, seconds per slot,
slots per epoch, epochs per sync committee period, router (IBC contract)
address and commitment slot; its latest slot must be strictly ahead of the
subject's, with a consensus state there. Forks after the subject's latest
slot may differ: a recovery can schedule a fork the subject did not know, or
recover a client stalled before one. `ethereum.RecoverClient` then copies
the substitute's latest consensus state into the subject, adopts its latest
slot and execution block number, its minimum sync committee
participation and its fork schedule, unfreezes the subject, and trusts nothing older: consensus
states below the copied one stop verifying proofs. The client's trust
generation grows with the recovery.

Emitted event:
```json
{
  "type": "recover_client",
  "attrs": [
    {
      "key": "subject_client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "substitute_client_id",
      "value": "07-tendermint-2"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## UpgradeClient

See [`zz_upgrade_client_example_filetest.gno`](./filetests/zz_upgrade_client_example_filetest.gno)

See [`upgrade-client.md`](./upgrade-client.md) for the lifecycle, the
proof shape, and the field mapping between the current client and the
upgraded client.

Emitted event:
```json
{
  "type": "upgrade_client",
  "attrs": [
    {
      "key": "client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    },
    {
      "key": "consensus_height",
      "value": "1/100"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## Pause / Unpause

`core.Pause` suspends the packet path: `SendPacket`, `RecvPacket`,
`WriteAcknowledgement`, `Acknowledgement` and `Timeout` panic with `core is
paused` until `core.Unpause`. Client operations (`CreateClient`,
`RegisterCounterparty`, `UpdateClient`, `UpgradeClient`, `RecoverClient`) keep
working, so relayers can keep clients alive during a pause. `Pause` is gated
by the authority (GovDAO or ibcgov, see below); `Unpause` is an ibcgov
decision. A pause stops the core's packet path, the transfer app's
callbacks included, so refunds that would arrive through acknowledgements
and timeouts wait: it is reserved for a core bug. It does not stop the
transfer app's local payouts of what is already booked: `Claim` keeps paying
claims and `ClaimRefunds` keeps paying queued refunds on an Ethereum route
during a pause. To stop those, use the route's flags (`payouts` stops claim
payouts and sweep payments, `refunds` holds refund payouts); they are the
incident tool for the Ethereum route (ADR pr6375 §7.3).

`core.Paused()` reports the state, which is also shown on `/r/aib/ibc/core:admin`.
In-flight packets are not lost: commitments, receipts and acknowledgements stay
in place and resume after `Unpause`; packets that time out meanwhile are
refunded by the usual timeout path once resumed.

Emitted events: `pause` and `unpause`, with no attributes.

## PauseApp / UnpauseApp

`core.PauseApp(portID)` suspends one application instead of the whole packet
path: `SendPacket` refuses payloads for that port (the sender's transaction
fails, nothing moves), and `RecvPacket` answers incoming packets for it with the
error acknowledgement without invoking the app, so the counterparty refunds its
senders. `Acknowledgement` and `Timeout` callbacks keep running, so refunds the
app owes are never held back. `core.UnpauseApp(portID)` resumes it. `PauseApp`
is gated by the authority (GovDAO constructor `NewPauseAppProposalRequest`);
`UnpauseApp` is an ibcgov decision. `IsAppPaused`
and the `paused` field of `/r/aib/ibc/core:apps` report the state. Applications
do not carry a pause switch of their own.

Emitted events: `app_paused` and `app_unpaused`, with a `port` attribute.

## Relayer whitelist

Client operations (`CreateClient`, `UpdateClient`, `UpgradeClient`) and packet
relaying (`RecvPacket`, `Acknowledgement`, `Timeout`) are restricted to the
relayers in a whitelist, checked against the transaction signer. Relaying for
an Ethereum client is the exception: its updates, receives, acknowledgements
and timeouts are open to anyone, whatever the whitelist holds (ADR pr6375
R17); `CreateClient` and `UpgradeClient` stay restricted for every client.
`/r/aib/ibc/core:admin` lists the whitelist. `SendPacket` is not restricted:
users send through their applications.

`AddRelayer(addr)` and `RemoveRelayer(addr)` are governed operations (see
[Authority](#authority)): the core accepts them from
`gno.land/r/aib/ibc/ibcgov` only, so an authority member or the deployer
calling them directly panics (`add_relayer: only gno.land/r/aib/ibc/ibcgov
decides this, not <caller>`) and leaves the whitelist as it was. They are made with the ibcgov builders
`ibcgov.NewCoreAddRelayerRequest(cur, addr)` and
`ibcgov.NewCoreRemoveRelayerRequest(cur, addr)`. Before the governor yields,
the governor records the decision with `MsgRun` (the request is a struct, so
`MsgCall` cannot build it), one `Govern` per relayer:

```gno
package main

import "gno.land/r/aib/ibc/ibcgov"

func main(cur realm) {
	ibcgov.Govern(cross(cur), ibcgov.NewCoreAddRelayerRequest(cross(cur), "<relayer-address>"))
}
```

```sh
gnokey maketx run ... <governor-key> add-relayer.gno
```

After the yield (or from the first block when ibcgov was deployed with no
`LaunchGovernor`), a GovDAO member proposes the same request instead, members
vote and anyone executes the proposal, which records the decision:

```gno
package main

import (
	"gno.land/r/aib/ibc/ibcgov"
	"gno.land/r/gov/dao"
)

func main(cur realm) {
	pid := dao.MustCreateProposal(cross(cur), ibcgov.NewCoreAddRelayerRequest(cross(cur), "<relayer-address>").Proposal())
	println("proposal", int64(pid))
}
```

Adding a relayer is a loosening decision: it is queued for 7 days in
production (`decisions.Delay`, shortened on a devnet build by
`decisions.Factor`), can be cancelled meanwhile and deferred by a guardian
hold. Once due, anyone applies it with the decision number the ledger
assigned (`gno.land/r/aib/ibc/ibcgov:decisions`):

```sh
gnokey maketx call -pkgpath gno.land/r/aib/ibc/ibcgov -func Execute -args <decision> ... <any-key>
```

**While the whitelist is empty, any address may do all of the above.** That
is the state right after deployment, and it lasts at least until the first
add-relayer decision executes, so no less than the 7-day delay after the
governor (or GovDAO) records it. During that bootstrap interval anyone can
create clients, including clients of a chain they run, and relay packets
from them: clients are never removed, and packets from such a client mint
vouchers only that client's counterparty backs. Record the add-relayer
decisions right after deploying, so the interval is no longer than the
delay. Removing the last
listed relayer reopens the same state, which is why that removal also waits
7 days.

## Authority

Administration is split by direction (ADR pr6375 R14):

- **Tightening operations** (`Pause`, `PauseApp`, `RejectApp`) act at once and
  are gated by an authority (`p/aib/authority`). Its initial members are
  the GovDAO proxy `gno.land/r/gov/dao` and the governance realm
  `gno.land/r/aib/ibc/ibcgov` (`IBCGovPath`). There is no deployer member.
  ibcgov can remove GovDAO at once (`NewCoreRemoveMemberRequest`); only
  ibcgov itself is irremovable, so GovDAO's tightening powers last only
  while it remains a member.
- **Governed operations** (`Unpause`, `UnpauseApp`, `ApproveApp`,
  `AddRelayer`, `RemoveRelayer`, `RecoverClient`, `UpdateImpl`,
  `MigrateClient`, `RetireClient`, `RetireClientPort`, `AddAuthorityMember`,
  `RemoveAuthorityMember`) are decisions of `gno.land/r/aib/ibc/ibcgov` alone,
  under its decision ledger, the governor's one-way yield to GovDAO and the
  guardians' holds. The loosening ones wait 7 days: `ApproveApp`,
  `AddRelayer`, `RecoverClient`, `UpdateImpl`, `MigrateClient`,
  `AddAuthorityMember`, and `RemoveRelayer` of the last listed relayer (an
  empty whitelist lets anyone relay). The others apply at once: `Unpause` and
  `UnpauseApp` (spent under a guardian hold), `RemoveAuthorityMember`, and
  `RemoveRelayer` while other relayers stay listed (the whitelist is read
  when the decision is recorded). `RetireClient` and `RetireClientPort` are
  not decisions of their own: a route replacement retires the route's old
  client, and ibcgov's acceptance of IBCAdmin's epoch notice finishes the
  retirement (see below). A call from anyone
  else, GovDAO's proxy included, panics with
  `only gno.land/r/aib/ibc/ibcgov decides this`.

The principal is the caller of the realm function, `cur.Previous()`, not the
transaction signer.

- `IsAuthorityMember(addr)`: reports membership; `/r/aib/ibc/core:admin` lists
  the members.

GovDAO acts on the tightening operations through proposals
(`NewPauseProposalRequest`, `NewPauseAppProposalRequest`,
`NewRejectAppProposalRequest`) returning a `dao.ProposalRequest` whose callback
runs the operation with the DAO proxy as caller. A GovDAO member submits it
with `MsgRun`:

```gno
pid := dao.MustCreateProposal(cross(cur), core.NewPauseProposalRequest(cross(cur)))
```

then members vote (`MustVoteOnProposalSimple`) and anyone executes
(`ExecuteProposal`), both plain `MsgCall`s on `gno.land/r/gov/dao`.

Emitted events: `authority_member_added` and `authority_member_removed`, with an
`address` attribute; `client_retired`, with a `client_id` attribute (and a
`port` attribute when the client is retired for one port only).

## Relaying for Ethereum clients

`UpdateClient`, `RecvPacket`, `Acknowledgement` and `Timeout` apply the relayer
whitelist only to non-Ethereum clients. For a client of type `ethereum`, every
one of them is permissionless (ADR pr6375 R17): all of them are proof-checked,
and a refund needs both a fresh client update and the acknowledgement or
timeout, so neither may wait on a listed relayer. `CreateClient` and
`UpgradeClient` keep the whitelist.

## Receipts

A received packet's receipt is `types.CommitPacketReceipt(packet)`, a sha256
commitment to the sequence, the source client and the packet's IBC v2
commitment, stored at the ICS24 receipt path (ADR pr6375 R19). It says which
packet occupies a sequence, so a reconciliation can recompute it from the
authenticated packet. Ordinary timeout processing proves only a receipt's
absence; Ethereum's reconciliation also proves its membership and compares
its value (`GnoICS20Evidence`). The same
packet relayed again is a no-op once the checks that come before the
receipt's pass (the destination client known, not retired and Active, the
counterparty registered and matching the source, the packet not timed out):
an identical retry at or after its timeout is refused like any late packet.
A different packet at a received sequence is refused.

## Client migration and retirement

`MigrateClient(clientID, migration, params)` migrates a live client while
keeping its id, consensus states and packet state, through an implementation
that implements `core.ClientMigrator` (ADR pr6375 R16). `impl/v1` has two
migrations.

`ethereum-verifier` (params: the target verifier version; ibcgov
`NewReplaceVerifierRequest(clientID, toVersion)`) replaces the client's
verifier by another verifier version. The conversion is code of a core
implementation: a later implementation compiles it in and declares it as
plain values (`implv1.NewWithConversions(store, version, from, to,
convert)`, each `convert` a function of the new verifier's /p/ package
receiving a read-only view of the live verifier, `ethereum.Retired`, so it
cannot write to it), and
is installed by the governed, manifest-checked implementation upgrade;
`impl/v1` itself declares none. No other code converts a verifier. The
active implementation's preflight reads its declared pairs and the client's
state (an Ethereum client, Active or Expired, never Frozen, its
`VerifierVersion` the declared source, and a verifier exposing its ethereum/v0 state through
`Ethereum() *ethereum.EthLightClient`, which the read-only view is built
from: a verifier keeping its state otherwise needs migration support of its
own, and is refused, the decision spent); the conversion and every check on its result (it names the target
version, keeps the live verifier's status, Active or Expired, its latest
height and, when it exposes ethereum/v0 state, the slot it trusts consensus
states from) run inside one recovered
boundary in the core's realm: a panic or a mismatch refuses the migration
with nothing changed, and the decision is spent; otherwise the verifier is
installed through `Client.SetLightClient`. The new verifier keeps the
client's history without copying it (`ethereum.NewFrom`): it holds a
read-only view of the retired verifier and serves every consensus state at
or below the retired verifier's latest slot from it, storing its own apart,
so every pre-replacement trusted height stays provable; nothing writes to
the retired verifier again. The client keeps its id and packet state; its
trust generation advances, and ibcgov empties its route's payout meters. An
Expired client is converted too and stays Expired, so a client whose updates
stopped long enough to expire is repaired by the conversion, then an
ordinary recovery (`RecoverClient`, with a substitute ahead of it); a Frozen
client is recovered first (transfer filetest `z9zu`).

`ethereum-fork-schedule` (params `ethereum.EncodeForkParameters(...)`)
changes the fork schedule of the client's verifier in place, through the
`CheckForkParameters` and `MigrateForkParameters` methods the verifier
implements: ethereum/v0's verifier, and a later version embedding it. A
verifier without them is refused when the decision is checked, and the
decision is spent. The new schedule is checked
(`ethereum.CheckForkParameters`, through `CheckMigrateClient`) when the
decision executes, before anything changes: the client must be Active, the schedule must differ from the current
one, the genesis fork version and slot never change, every fork already
active at the current epoch (the later of the latest trusted slot's and the
block time's) keeps its version and epoch, every changed fork activates after
the current epoch, and the schedule passes the checks of a created client's
(epochs in order, a version for every scheduled fork). A fork whose containers
change needs a new verifier version, installed by `ethereum-verifier`.

`RetireClient(clientID)` marks the client retired in the proxy, for a route
replacement (ADR pr6375 §7.12, R18; the parent ADR freezes the old client,
the retirement marker stands in for that). It refuses every later packet
message, update, registration and recovery naming the client, with one
exception: the app that registered a packet's port may still write a pending
asynchronous acknowledgement for a packet the client received before its
retirement (`WriteAcknowledgement`), so the packet reaches a terminal state.
The verifier itself is untouched: its status stays what it was (the `z16b`
filetest reports `retired: true status: Active`), and `IsClientRetired`, not
the status, tells a retired client apart. Both are governance decisions; the
retirement happens inside a route replacement.

`RetireClientPort(clientID, port)` retires a client for one port only: every
packet message naming the client with a payload on that port (its source
port when sent from here, its destination port when received) is refused,
while its other ports, its updates and its counterparty stay
(`IsClientRetiredFor(clientID, port)`). A route replacement retires the old
client for the `transfer` port only while ibcgov's governance epoch runs
over it, or while it is the client of a transition or tombstone on
ibcgov's expected graph at any distance, so governance packets in flight
can still be re-sent over it and a later notice can still arrive; and, on
the governed Ethereum route once ibcgov's channel is bound, also when the graph
does not hold it and no epoch switch has passed it, since a catch-up may
need it later. ibcgov retires a client for governance only when an
authenticated epoch switch leaves it as the old epoch's client (the path's
intermediate clients are kept, since whoever applies a notice names the
path); a switch's pruning and a tombstone purge never
retire anything: the clients they disconnect are kept off the graph, gov
port open and inert, and `PruneGovRetirements` retires nothing a switch
did not pass (ADR 0004, Governance channel; transfer filetests `z9zv`,
`z9zza`, `z9zzq`, `z9zzu`).

`ClientRouteIdentity(clientID)` is the history a client's verifier
authenticates, and the router it reads: for an Ethereum client its chain
id, genesis validators root, ICS26 router and commitments slot, all fixed at
creation (`IdentifiedVerifier`; `""` for a client whose verifier names
none). A route records it at its enrolment, and a replacement client must
name the same one.

The read accessors `ClientType`, `CounterpartyClientID`, `IsClientRetired`,
`IsClientRetiredFor`, `ClientRouteIdentity`,
`PacketCommitment`, `PacketReceipt`, `PacketAcknowledgement` and
`HasPendingAsyncAck` return copies, for realms (the transfer app, ibcgov) that
must check a packet's state.

## Upgrades

This realm is a permanent, thin proxy (see
[ADR 0001](../../../../../docs/adrs/0001-proxy-realm-for-core-upgrades.md)): it
owns the state, the chain params and the events, which must never move, and
forwards every entry point to an implementation realm that holds the client and
packet lifecycle logic. The first one is `gno.land/r/aib/ibc/core/impl/v0`.

An implementation registers itself from its `init` with `RegisterImpl`; the
first registration activates at once (bootstrap), every later one is only a
candidate until an `UpdateImpl` decision of `gno.land/r/aib/ibc/ibcgov`
(7 days) activates it. The
new implementation is built against the same store and its `OnInstall` hook
runs before the switch, so clients, commitments, receipts and acknowledgements
survive and a failing migration leaves the current implementation active.
Rollback is `UpdateImpl` with the previous path. `ImplPath()` and
`ImplVersion()` tell which one is active; the home and `admin` pages show it.
Nothing outside the chain changes during an upgrade: this path, the entry
points, the events and the render routes are the proxy's, so the relayer, the
counterparty and the users keep using them. The steps are in
[`docs/upgrade-runbook.md`](../../../../../docs/upgrade-runbook.md).

`Render` is forwarded to the implementation as well, JSON routes included, so
the routes can follow the verifier they read across upgrades. The routes the
relayer consumes (`clients`, `clients/{id}`, its consensus states, packet
commitments and receipts) are a compatibility contract pinned by the `z0c`
filetest: a change there means a relayer release. `clients/{id}/consensus_states`
lists, paginated, an Ethereum client's consensus states as a Tendermint
client's (`z16h`): those its verifier stores itself, a state below a
recovery's cut-off listed as untrusted; after a verifier replacement, the
retired verifier's states are served one height at a time
(`clients/{id}/consensus_states/{revision}/{height}`).

Emitted event:

```json
{
  "type": "impl_updated",
  "attrs": [
    {"key": "old_path", "value": "gno.land/r/aib/ibc/core/impl/v0"},
    {"key": "new_path", "value": "gno.land/r/aib/ibc/core/impl/v1"},
    {"key": "version", "value": "v1"}
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```
