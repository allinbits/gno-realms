# ADR 0003: Ethereum light client and Solidity ICS20 interoperability

- Status: Proposed
- Date: 2026-10-15

## Context

The goal is IBC v2 between gno.land and Ethereum (Sepolia first), with the
solidity-ibc-eureka contracts (ICS26 router, ICS20 transfer) on Ethereum. On
the gno side that needs a light client of Ethereum, and three constraints
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
- Every header and every misbehaviour builds on the latest trusted state: its
  `TrustedSlot` must equal the client state's `LatestSlot`
  (`checkLatestAnchor`). Older stored consensus states stay usable for
  membership proofs at their heights (those from before a recovery
  excepted; authenticating a newer state does not make them genuine, so an
  incident's suspect interval starts no later than the earliest stored
  root that may have been forged: ADR 0004, runbook §8), but never as the
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
  before submitting it. The header names the signing committee
  (`ActiveIsNext`): the trusted current committee for an update signed in the
  stored period, the trusted next committee for one signed in the following
  period; any other choice, or a signature period beyond the next, is
  refused. An update's next committee is accepted only when its branch
  verifies, and, for an attested header in the stored period signed by the
  trusted next committee, only when it equals that committee.
- An update that crosses into the next period promotes the trusted next
  committee to current and takes the update's next committee, if it carries
  one, as the new next; an update without one leaves the next committee
  unknown, and the client then needs a later update in the new period that
  reveals it before it can follow the following rotation.
- An update must carry at least the client state's
  `MinSyncCommitteeParticipants` signers (`validateUpdate`), and to move the
  client a 2/3 supermajority of the committee besides: participants * 3 >=
  `SyncCommitteeSize` * 2, 342 of 512 (`hasSupermajority`).
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
- Before Gloas the execution state root comes from the execution payload
  header. From Gloas on, the relayer supplies the RLP execution header, whose
  keccak256 must equal the committed block hash.
- An update that only reveals the next sync committee is accepted even when it
  does not advance finality, as in the spec's `apply_light_client_update`.
  Beacon nodes only serve bootstraps at recent checkpoints, so a client often
  starts late in a period, and the period's best update (the only one carrying
  the next committee) is usually older than that. Eureka's client rejects such
  updates; without them this client would get stuck at the period boundary.
- Membership is proven with account and storage MPT proofs against the
  finalized execution state root, at the router's
  `commitments[keccak256(path)]` slot. Non-membership is a proof of the zero
  value. Consensus states are stored at height
  `{RevisionNumber: 0, RevisionHeight: <finalized beacon slot>}`: a proof
  height names a beacon slot, never an execution block number. A proof is
  refused at a nonzero revision, at a slot after the client's `LatestSlot`,
  and at a slot with no trusted consensus state stored (not one the client
  was updated to, or one from before a recovery).

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
- The client expires when the current slot passes its latest trusted slot by
  more than `TrustingPeriods` (8) sync committee periods' worth of slots:
  current slot > `LatestSlot` + 8 * `EpochsPerSyncCommitteePeriod` *
  `SlotsPerEpoch` (`expired`). It counts slots, not period numbers, so the
  window is the same wherever in a period the latest slot falls. Until then
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
  client of another router or chain is refused.
