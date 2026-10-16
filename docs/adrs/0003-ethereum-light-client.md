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
- Finality, next sync committee and execution branches are checked with the
  generalized indices of the attested slot's fork: Electra/Fulu, or Gloas.
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
  value.

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
- The client does not expire on its own: one that misses a whole sync
  committee period cannot verify updates and must be recovered.
