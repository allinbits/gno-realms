# ADR 0003: Ethereum light client and Solidity ICS20 interoperability

- Status: Proposed
- Date: 2026-10-15

## Context

The goal is IBC v2 between gno.land and Ethereum (Sepolia first). The
Ethereum side is [allinbits/gno-eth-ibc](https://github.com/allinbits/gno-eth-ibc).
Its `main` deploys the ICS26 router and ICS20 transfer app of
solidity-ibc-eureka v3.0.2 unchanged, with a Solidity light client of
gno.land, the voucher token and a relayer. Its `feat/ibc-controls` branch,
which goes with this repo's of the same name, adds a minimal fork of the ICS20
app with route controls, the IBCAdmin app through which gno.land's governance
runs them, and an emergency route recovery;
[docs/controls.md](https://github.com/allinbits/gno-eth-ibc/blob/feat/ibc-controls/docs/controls.md)
lists them and every change against eureka. The design of both sides is the
gno ADR [`gno.land/adr/pr6375_ibc_ethereum.md`](https://github.com/gnolang/gno/blob/feat/secp256k1-validators-ibc/gno.land/adr/pr6375_ibc_ethereum.md).

On the gno side that needs a light client of Ethereum, and three constraints
shape it:

1. **Proof format.** Ethereum state is proven with Merkle-Patricia account and
   storage proofs (`eth_getProof`), not ICS23. The packet messages carry their
   proof in `[]ics23.CommitmentProof` fields, and the message types, the
   `lightclient.Interface` and the core proxy's signatures are frozen
   (ADR 0001): a deployed chain cannot change them.
2. **Verification cost.** Each update verifies a BLS12-381 aggregate
   signature of the sync committee (512 keys). That needs a native: gno's
   `crypto/bls12381.FastAggregateVerifyExcluding`.
3. **Payload encoding.** The Solidity ICS20 app only reads and writes
   `abi.encode(FungibleTokenPacketData)` under the encoding
   `application/x-solidity-abi`; this transfer app only spoke protobuf.

Sepolia also runs Gloas (ePBS) since epoch 353024. From Gloas on a light-client
header carries the latest execution block hash, not the execution payload
header, and the light-client generalized indices moved (EIP-7688, EIP-7732).

## Decision

**Proof route.** `p/aib/ibc/lightclient/extproof/v0` defines `Proof{Data any}`,
which a relayer puts in a message's `Ext` field (reserved by ADR 0001 for
exactly this), and a `Verifier` interface. The core implementation verifies
through `Verifier` when `Ext` carries a `Proof` and the ICS23 field is empty,
applying the rest of `ValidateBasic` itself. Messages without one take the
existing path unchanged, so the tendermint client and the deployed relayer are
unaffected.

**Client.** `p/aib/ibc/lightclient/ethereum/v0` ports the Ethereum light client
of solidity-ibc-eureka (client type `ethereum`):

- Updates follow the Altair sync protocol: the trusted state keeps summaries
  (pubkeys root, aggregate key) of the current and next committees. Updates
  never carry a committee's 512 keys: a next committee travels as its
  summary, which is all its branch commits to, and the signature is checked
  with `crypto/bls12381.FastAggregateVerifyExcluding` against the trusted
  aggregate key minus the non-signers, which the update lists with Merkle
  branches to the pubkeys root. The committee commits to its aggregate key
  next to its keys, so this equals verifying over the signers' keys.
- **Creation trusts its input.** `CreateClient` takes the client and
  consensus states as given (core checks their shape with `ValidateBasic`):
  there is no bootstrap proof, as for any IBC client's creation, so whoever
  creates the client vouches for its committees and state root.
- Every header and every misbehaviour builds on the latest trusted state: its
  `TrustedSlot` must equal the client state's `LatestSlot`
  (`checkLatestAnchor`). Older stored consensus states stay usable for
  membership proofs at their heights (those from before a recovery
  excepted; authenticating a newer state does not make them genuine, and a
  genuine root does not make a defective verification against it sound, so
  an incident's suspect interval starts no later than the earliest stored
  root that may have been forged and the earliest proof an affected
  verifier version checked: ADR 0004, runbook §8), but never as the
  anchor of an update,
  so a past sync committee cannot insert state roots below the latest slot
  or freeze the client: an update or misbehaviour is verified only against
  the latest anchor and only by the committee of its period or the next
  (the committee-period checks below). Sync-committee signatures are not
  slashable at all, so this protection rests on those checks alone, not on
  any penalty a rotated-out committee would risk.
- An update is accepted only if its slots satisfy `signatureSlot >
  attestedSlot >= finalizedSlot`, the finalized slot is not the genesis
  slot, and `signatureSlot` is not after the current slot, which the client
  derives from gno.land's block time (genesis time, seconds per slot): a
  relayer must wait for gno.land's block time to reach a signature slot
  before submitting it. Updates are validated as in the spec's
  `validate_light_client_update`: whether the next committee is known comes
  from the trusted state, which keeps its summary, and the signing committee
  from the signature period: the trusted current committee for an update
  signed in the stored period, the trusted next committee, which must be
  known, for one signed in the following period; a signature period beyond
  the next is refused. An update's next committee is accepted only when its
  branch verifies, and, for an attested header in the stored period when the
  trusted state knows its next committee, only when it equals that one; an
  update may carry no next committee at all. The
  header's `ActiveIsNext` flag is ignored: it stays in `Header`,
  `Misbehaviour` and the wire format only because the format is positional
  and the relayers send it, and goes when they stop.
- An update that crosses into the next period promotes the trusted next
  committee to current and takes the update's next committee, if it carries
  one, as the new next; an update without one leaves the next committee
  unknown, and the client then needs a later update in the new period that
  reveals it before it can follow the following rotation.
- An update must carry at least the client state's
  `MinSyncCommitteeParticipants` signers (`validateUpdate`), and to move the
  client a 2/3 supermajority of the committee besides: participants * 3 >=
  `SyncCommitteeSize` * 2, 342 of 512 (`hasSupermajority`), and a
  finalized header. There is no optimistic header and no force update
  (`process_light_client_store_force_update`). A finality halt stalls the
  client for good only if no update finalizing a header after its latest
  slot is signed within the stored period, or the next one when the next
  committee is known: an update signed later has no committee the client
  trusts, and older ones finalize nothing new. With the next committee
  unknown, a next-committee-only update can still reveal it during the halt
  and so extend the window by a period. A halt shorter than that
  window, even longer than a period, is crossed by the first update after it.
  Otherwise the client expires and governance recovers it.
- Misbehaviour is conflicting finality: two updates, both valid against the
  latest trusted state, that finalize different beacon headers at the same
  slot, each meeting the 2/3 supermajority an update needs, not only the
  configured minimum. Different attested heads alone are not misbehaviour, since a
  reorg yields two. A header that passes verification but would store a
  different execution state root at a slot the client already holds is
  misbehaviour too (`CheckForMisbehaviour`). Either freezes the client.
- The finality and next sync committee branches are checked with the
  generalized indices of the attested slot's fork: Electra/Fulu, or Gloas.
  Each header's execution branch (the attested and the finalized one) is
  checked with the indices of that header's own beacon slot, so an update
  whose finalized header precedes Gloas and whose attested header follows it
  verifies each against its own fork. Headers before Electra are refused
  (`verifySupportedFork`): their indices differ from the ones this client
  uses.
- An Electra or Fulu header may come in either form: with its execution
  payload header (gindex 25), or in the form Gloas' `upgrade_lc_header_to_gloas`
  gives it and a Gloas-era beacon API serves, only the payload's block hash
  (gindex 812, its branch normalized to Gloas' 11 nodes). Relayers may send
  either. A Gloas header has only the block-hash form, and a header carrying
  both forms, or neither, is refused.
- The execution state root, timestamp and block number come from the
  finalized header's execution payload header, or, for a header in the
  block-hash form, from the RLP execution header the relayer supplies, whose
  keccak256 must equal that hash. Before Gloas the hash is the block's own
  payload; from Gloas on it is the bid's `parent_block_hash`, so the client
  tracks the parent execution block of the finalized beacon block. Relayers
  choose proof heights, and a client's creator its bootstrap state root, by
  the same rule.
- An update that only reveals the next sync committee is accepted even when it
  does not advance finality, as in the spec's `apply_light_client_update`,
  provided its finalized header is in the attested header's period (the
  spec's `update_has_finalized_next_sync_committee`): a period's next
  committee is final only once a header of that period is.
  Beacon nodes only serve bootstraps at recent checkpoints, so a client often
  starts late in a period, and the period's best update (the only one carrying
  the next committee) is usually older than that. Eureka's client rejects such
  updates; without them this client would get stuck at the period boundary.
- The fork schedule picks the signing domain, the generalized indices and
  the supported range, so `ClientState.ValidateBasic` refuses one no update
  could pass: fork epochs out of order, a scheduled fork without a version (a
  zero `Fork{}` reads as active from genesis), Electra unscheduled, a
  latest slot before Electra, or a `ForkParameters.GenesisSlot` other than
  the client state's `GenesisSlot`. That field duplicates the client
  state's, which the client computes with; it is kept, required equal, for
  parity with eureka's fork parameters and the wire formats that carry it.
- `RecoverClient` requires the substitute to track the same chain and
  router (chain id, genesis validators root, genesis fork version, genesis
  slot, slot clock, committee size, router address and commitments slot), to pass
  `ValidateBasic`, its fork schedule included, and to be ahead; the subject
  adopts the substitute's schedule. No fork comparison binds the two
  schedules, and none binds a fork-schedule migration or a verifier
  replacement's result either: both must pass the creation checks
  (`CheckForkParameters`, `Retired.CheckSuccessor`, ADR 0004 R16), keep the
  genesis fork, and, for a replacement, the chain and router. Once a client
  exists, its schedule changes only on governed paths (recovery, and on later core implementations a fork migration or a
  verifier conversion), and governance already has full power over a client
  through recovery from a substitute it created from a trusted bootstrap,
  so a comparison adds no safety against governance. A new client's
  schedule, like the rest of its initial state, is trusted from its creator:
  a whitelisted relayer, or anyone while the whitelist is empty. A wrong
  schedule cannot make a relayed update verify false data. The update still
  needs a 2/3 sync committee signature over the chain's real domain, with
  Merkle proofs into signed roots. And a wrong Merkle layout (the Gloas flag
  on the wrong side of the fork) puts each generalized index of the other
  fork on a value no relayer chooses:
  - Electra's 169 in a Gloas state lands on `fork.current_version`; its 87
    falls under `latest_block_header`, and a committee matching there would
    need a zero aggregate key, which cannot verify;
  - 25 and 812 in a Gloas body fall under its active-fields leaf;
  - Gloas' 735, 2946 and 2856 in Electra or Fulu containers fall on uint64
    leaves, length mix-ins, or, in a body, the deposits list (empty since the
    EIP-6110 transition; otherwise a deposit hash node, which still needs a
    preimage).

  A governed recovery, unlike a relayed update, adopts its substitute's
  state as trusted. At worst a wrong schedule stops the client from
  verifying, which another governed action repairs. Each comparison rule
  tried made some stalled or wrongly configured client unrepairable: what an
  update was "verified under" rests partly on its signature slot, which the
  spec marks untrusted and anyone can relabel within a period, and partly on
  the very schedule being repaired. A fork that changes container layouts
  needs the index analysis above redone, one more reason it needs a new
  client package.
  This only covers forks the package knows: `ForkParameters` has no slot
  after Gloas, and a fork that moves the light-client containers needs a new
  client package.
- Core recovers only a Frozen or Expired client. An Active client facing a
  fork its schedule lacks is repaired by the governed fork-schedule
  migration (`ethereum-fork-schedule`, ADR 0004 R16), which may schedule the
  fork before or after its activation, so a missed deadline does not mean
  waiting for expiry.
- Membership is proven with account and storage MPT proofs against the
  finalized execution state root, at the router's
  `commitments[keccak256(path)]` slot. Non-membership is a proof of the zero
  value. Consensus states are stored at height
  `{RevisionNumber: 0, RevisionHeight: <finalized beacon slot>}`: a proof
  height names a beacon slot, never an execution block number. A proof is
  refused at a nonzero revision, at a slot after the client's `LatestSlot`,
  and at a slot with no trusted consensus state stored (not one the client
  was updated to, or one from before a recovery).
  A membership path has exactly one element, the ICS24 key (the router's
  merkle prefix is empty).

**Transport.** Relayers send client messages and packets as `[]byte`
`MsgCall` arguments to `r/aib/ibc/ethrelay`, in the positional wire format of
`gno.land/p/aib/encoding/wire/v0` (from clockworkgr/gno-upgradeable), which decodes
them and forwards them to the core. `MsgRun` scripts paid 1,250 gas per byte
of preprocessing on update literals; a `[]byte` argument is base64-decoded
natively. Together with the non-signer scheme this took a live Sepolia
finality update from 641M gas to 40M, with messages of about 2.5 KB.
The core bounds a packet's payload data, not the message:
`types.MaximumPayloadsSize`, 262,144 bytes, is the sum of
`len(Payload.Value)`, the same on every route. A packet from the router over
it is refused by the core before any proof is verified, with no receipt and
no error acknowledgement, so it stays pending on Ethereum until it times out
(core README, Packet limits).

**Encoding.** `p/aib/ibc/ics20/abi/v0` encodes and decodes the Solidity layout.
The transfer implementation accepts either encoding on receive, ack and
timeout, and sends ABI over `ethereum-*` clients. `Transfer`'s signature is
unchanged.

## Alternatives considered

- **Change the message and interface types to opaque proof bytes**, as ibc-go
  does. Cleaner, but impossible on a deployed chain, and breaks the relayer.
- **A ZK or attestation-based Ethereum client.** Cheaper updates, but either a
  prover service or a trusted signer set.
- **Pick the ICS20 encoding by a new Transfer argument.** Changes a frozen
  signature; the client type already says which encoding the counterparty
  reads.

## Consequences

- Consensus-state storage grows with every accepted finalized height: each
  advancing update stores a consensus state, and nothing prunes them. A
  recovery only stops trusting the states below the substitute's (they no
  longer verify proofs); they stay allocated.
- The deployment is fresh: core `impl/v0` serves Ethereum clients itself
  (`core/impl/v1` adds the client migrations: a fork schedule, or a verifier
  replacement by a conversion a later core implementation compiles in, the
  new verifier continuing the retired one's history read only through
  `ethereum.NewFrom`: an index of the retired verifiers' own stores, keyed
  by each one's latest slot and holding non-overlapping intervals, read in
  O(log replacements) however many replacements there were; a retired
  store joins it only when its latest slot is above the index's highest
  key, so no key is re-pointed and no older interval lost, and any state it
  holds at or below that key (a rewritten head, a next committee learned
  there) goes into a persistent override tree read first; a conversion
  copies no consensus-state history and costs O(log previous stores)), and the
  transfer
  app starts with `impl/v1`, the first implementation its proxy registers;
  the new `p/` packages deploy beside them.
- Tests replay the four recorded devnet runs of the eureka client (11 updates,
  6 storage proofs), a live Sepolia snapshot on Gloas, and tamper cases. A
  Solidity payload decodes and re-encodes byte for byte.
- Cases no recorded chain gives come from synthetic data built from the specs
  (`zz_synthetic_test.gno`, written by `cmd/gen-eth-synthetic`): a sync
  committee of 32 BLS keys derived from a fixed seed signs, with blst, while
  the client verifies with gnark-crypto. The generator computes SSZ roots,
  domains and signing roots from the consensus specs, never from the
  client's code. The chain is a minimal-preset chain. The attested beacon
  states and bodies and the execution payloads are built as their
  containers (Gloas' as progressive containers), and every value fixed by
  the block itself, by its fork upgrade (the Gloas block is the fork block)
  or by the epoch transition before it follows the spec: basic fields,
  versions, padding, active-fields words and progressive terminators; the
  justification bits and checkpoints, picked by running the spec's
  `weigh_justification_and_finalization` over the history; the latest
  block header, the bid's parent root and the recorded bid; the Gloas
  fields `upgrade_to_gloas` and the bid set (payload availability, builder
  payments and withdrawals); empty operation and request lists; empty
  payloads with their empty roots, timestamps at their slot's time and
  parent beacon roots per EIP-4788. Fields that depend on earlier chain
  history (registries, randao, root vectors, parent hashes and the like;
  the generator's header lists each) are arbitrary chunks from the seed, so
  the data is not a replayable chain; the light client reads none of them.
  Each update finalizes a checkpoint at least two epochs behind its
  attested head.
  Canonical, as the specs have them: a Gloas update whose finalized header
  is still Fulu, upgraded to the block-hash form (gindex 812) with its full
  RLP execution header; a Fulu update with both headers in the payload form;
  a valid conflicting-finality misbehaviour of two Gloas updates, through to
  Frozen; and a Gloas update with non-signers, refused when they are
  reordered, proven at another index or missing, or when a share is signed
  outside the committee. One client-compatibility case is outside the spec:
  the Gloas update with its Fulu finalized header left in the payload form,
  which a Gloas `LightClientHeader` cannot hold but this client accepts.
  `go test -C cmd/gen-eth-synthetic` checks that the committed file is what
  the generator writes.
- The client expires when the current slot passes its latest trusted slot by
  more than `TrustingPeriods` (8) sync committee periods' worth of slots:
  current slot > `LatestSlot` + 8 * `EpochsPerSyncCommitteePeriod` *
  `SlotsPerEpoch` (`expired`). It counts slots, not period numbers, so the
  window is the same wherever in a period the latest slot falls, and
  `ValidateBasic` bounds the slot parameters so that it never wraps. Until then
  it can catch up through successive periods, each update signed in the
  stored period or the next one (with the next committee), which it learns
  period by period; once expired it accepts no update or misbehaviour and
  must be recovered by governance. On mainnet the window is about 9.1 days
  (8 × 256 epochs × 32 slots × 12 s). A governed verifier replacement (ADR
  0004, R16) converts an Expired client too, keeping it Expired and keeping
  the slot it trusts consensus states from, so a stall that outlasts the
  window is repaired by the conversion, then that ordinary recovery; a
  Frozen client is refused. The runbook (§7, step 7) gives the preparation
  deadline and the missed-deadline procedure.
- Every field a route's history depends on is fixed at creation: the chain
  id, the genesis validators root, the ICS26 router address and its
  commitments slot (`EthLightClient.RouteIdentity`, read through
  `core.ClientRouteIdentity`). A route records them at its enrolment, and a
  replacement client must name the same ones (ADR 0004, R18): a genuine
  client of another router or chain is refused. The fork schedule is not
  part of it: a fork migration, a recovery or a verifier replacement may
  change it, governed, and no path compares the old schedule with the new
  one (see `RecoverClient` above). A route replacement (R18) holds no fork
  rule between the old client and the new one either; it is also the path
  for a compromised or defective client, whose schedule is what is in doubt. Governance vets the
  new client's schedule (runbook step 0). A chain split after the old
  client's latest epoch, both sides keeping the chain id and genesis
  validators root, cannot be told apart by any parameter check on any path:
  choosing the canonical side is governance's job.
