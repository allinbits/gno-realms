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
   `crypto/bls12381.FastAggregateVerify`.
3. **Payload encoding.** The Solidity ICS20 app only reads and writes
   `abi.encode(FungibleTokenPacketData)` under the encoding
   `application/x-solidity-abi`; this transfer app only spoke protobuf.

Sepolia also runs Gloas (ePBS) since epoch 353024. From Gloas on a light-client
header carries the latest execution block hash, not the execution payload
header, and the light-client generalized indices moved (EIP-7688, EIP-7732).

## Decision

**Proof route.** `p/aib/ibc/lightclient/extproof` defines `Proof{Data any}`,
which a relayer puts in a message's `Ext` field (reserved by ADR 0001 for
exactly this), and a `Verifier` interface. The core implementation verifies
through `Verifier` when `Ext` carries a `Proof` and the ICS23 field is empty,
applying the rest of `ValidateBasic` itself. Messages without one take the
existing path unchanged, so the tendermint client and the deployed relayer are
unaffected.

**Client.** `p/aib/ibc/lightclient/ethereum` ports the Ethereum light client
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
- **One anchor.** Every header and every misbehaviour builds on the latest
  trusted state: its `TrustedSlot` must equal `LatestSlot`
  (`checkLatestAnchor`). Older consensus states stay usable for proofs but
  never anchor an update, so a past committee cannot insert roots below the
  latest slot or freeze the client.
- **Finality only.** Every update that moves the client needs a 2/3
  supermajority of the committee (participants * 3 >= `SyncCommitteeSize` *
  2, 342 of 512), besides the configured `MinSyncCommitteeParticipants`, and a
  finalized header. There is no optimistic header and no force update
  (`process_light_client_store_force_update`): if Ethereum stops finalizing
  for longer than a period, the client stalls and expires, and governance
  recovers it.
- The finality and next sync committee branches are checked with the
  generalized indices of the attested slot's fork: Electra/Fulu, or Gloas.
  Each header's execution branch (the attested and the finalized one) is
  checked with the indices of that header's own beacon slot, so an update
  whose finalized header precedes Gloas and whose attested header follows it
  verifies each against its own fork. Headers before Electra are refused.
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
- Updates are validated as in the spec's `validate_light_client_update`:
  `current >= signature > attested >= finalized`, a finalized slot other
  than the genesis slot, and a signature slot in the stored period or the
  next. Whether the next committee is known comes from the trusted state,
  which keeps its summary, and the signing committee from the signature
  period: the current one within the stored period, the stored next one in
  the period after. An update that carries a next committee, attested in the
  stored period, must carry the one the state already knows, if it knows
  one; an update may carry none. The header's `ActiveIsNext` flag is
  ignored: it stays in `Header`, `Misbehaviour` and the wire format only
  because the format is positional and the relayers send it, and goes when
  they stop.
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
  zero `Fork{}` reads as active from genesis), Electra unscheduled, or a
  latest slot before Electra.
- `RecoverClient` keeps the forks the subject verified signed updates under
  and takes the rest of the substitute's schedule: at every epoch from the
  lowest slot an applied update read (its finalized slot) to the highest (its
  signature slot minus one), the fork version, the Gloas layout and Electra
  support must be the same in both schedules. Elsewhere they may differ:
  governance can schedule a fork the chain announced after the client was
  created, recover a client stalled before one, or repair a schedule the
  client never verified anything under. The initial consensus state is
  trusted, not verified, so a client created with a wrong schedule for a fork
  already active at its creation, which accepts no update, may take any valid
  schedule. Comparing at the substitute's latest slot instead would refuse
  the stalled client's recovery; comparing every fork active at the subject's
  latest slot would refuse the wrongly created one's. This only covers forks
  the package knows: `ForkParameters` has no slot after Gloas, and a fork that
  moves the light-client containers needs a new client package.
- Core recovers only a Frozen or Expired client. On this branch alone, a
  client facing a fork its schedule lacks keeps rejecting updates while it
  stays Active, so a fork announced after creation means waiting for it to
  expire (8 periods after its latest slot, about 9.1 days on mainnet) and
  then recovering it; the route-controls branch (#84) adds a governed
  fork-schedule migration for an Active client.
- Misbehaviour is conflicting finality: two updates, both valid against the
  latest trusted state and each signed by a 2/3 supermajority, that finalize
  different beacon headers at the same slot. Different attested heads alone
  are not evidence, since a reorg yields two. A verified header that would
  store a different execution state root at a slot the client holds is
  misbehaviour too. Either freezes the client.
- Membership is proven with account and storage MPT proofs against the
  finalized execution state root, at the router's
  `commitments[keccak256(path)]` slot. Non-membership is a proof of the zero
  value. A membership path has exactly one element, the ICS24 key (the
  router's merkle prefix is empty), and a proof height is revision 0 at a
  stored finalized slot.

**Transport.** Relayers send client messages and packets as `[]byte`
`MsgCall` arguments to `r/aib/ibc/ethrelay`, in the positional wire format of
`gno.land/p/aib/encoding/wire/v0` (from clockworkgr/gno-upgradeable), which decodes
them and forwards them to the core. `MsgRun` scripts paid 1,250 gas per byte
of preprocessing on update literals; a `[]byte` argument is base64-decoded
natively. Together with the non-signer scheme this took a live Sepolia
finality update from 641M gas to 40M, with messages of about 2.5 KB.

**Encoding.** `p/aib/ibc/ics20/abi` encodes and decodes the Solidity layout.
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

- On an already deployed chain these changes ship as new implementation
  versions (`core/impl/v1`, `transfer/impl/v1`) and new `p/` packages; this
  branch edits `impl/v0` in place for the local testnet.
- Tests replay the four recorded devnet runs of the eureka client (11 updates,
  6 storage proofs), a live Sepolia snapshot on Gloas, and tamper cases. A
  Solidity payload decodes and re-encodes byte for byte.
- The client expires `TrustingPeriods` (8) sync committee periods' worth of
  slots after its latest trusted slot, and then refuses updates and
  misbehaviour until recovered. Until then a client that fell behind catches
  up: the signature slot is bounded only from above, by the current slot, so
  a relayer replays each missed period's update (the beacon API's
  `light_client/updates`), one period at a time. `ValidateBasic` bounds the
  slot parameters so that the window never wraps.
