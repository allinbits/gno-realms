# ADR 0006: Opaque byte proofs

- Status: Proposed
- Date: 2026-11-17
- Supersedes: ADR 0003's "Proof route" decision (the `extproof` package and
  the Ethereum proof in the messages' `Ext` field), and the parts of ADR 0001
  that rely on it (`impl/v0` reading `Ext`, `UpgradeClient`'s `any` proofs).
- Depends on: ADR 0001, ADR 0003.

## Context

The core's packet messages carried their proof as Gno values:
`MsgRecvPacket.ProofCommitment`, `MsgAcknowledgement.ProofAcked` and
`MsgTimeout.ProofUnreceived` were `[]ics23.CommitmentProof`, and
`lightclient.Interface`'s `VerifyMembership` and `VerifyNonMembership` took
the same type. ibc-go does not: its messages carry proofs as `bytes`, and
each light client decodes them (the Tendermint client a protobuf
`MerkleProof`). Typing the proofs in Gno cost three things.

1. **Caller code in the core.** `ics23.CommitmentProof` is an interface. A
   `MsgRun` caller could pass its own implementation, whose `GetExist` or
   `GetNonexist` would then run in the core's realm context. The core
   guarded against it with `ics23.CheckProofs` (Codex round 19), which every
   message's `ValidateBasic` and the Tendermint client had to call before
   touching a proof: a guard every new path had to remember.
2. **A second proof route.** An Ethereum client proves storage with
   Merkle-Patricia proofs, which do not fit the ICS23 type. ADR 0003 carried
   them in the messages' `Ext` field as an `extproof.Proof{Data any}`, read
   by `impl/v0` through `extproof.FromExt` and checked through a second
   interface, `extproof.Verifier`, beside an empty ICS23 field; the core
   branched on which of the two a message carried, and applied the rest of
   `ValidateBasic` itself on the `Ext` side. `UpgradeClient`, the core's
   `CounterpartyValue` and transfer's `ProveOutcome` took `any` proofs, each
   type-switched by the client.
3. **Gno source in the relayer.** A relayer had to turn the proof it read
   from the counterparty's ABCI query (protobuf bytes) into Gno literals of
   `ics23.ExistenceProof`, `LeafOp` and `InnerOp` for a `MsgRun`.

Nothing is deployed yet. Once the first mainnet deploy freezes the core
proxy's signatures, the message types and `lightclient.Interface` (ADR 0001,
"Frozen surface"), changing the proof type would take a new proxy at a new
path, a relayer release and a counterparty re-registration.

## Decision

**Proofs are opaque `[]byte` everywhere, decoded by the light client that
verifies them**, as in ibc-go:

- the proof fields of `MsgRecvPacket`, `MsgAcknowledgement` and `MsgTimeout`;
- `lightclient.Interface`'s `VerifyMembership(height, proof []byte, path,
  value)` and `VerifyNonMembership(height, proof []byte, path)`, and the two
  proofs of `VerifyUpgradeAndUpdateState` and of the core's `UpgradeClient`
  (the upgraded client and consensus states stay `any`);
- the core's `CounterpartyValue`, the Ethereum client's `ProvenValue` and
  transfer's `ProveOutcome`.

The core has one verification path: it checks that the proof is not empty
and hands the bytes to the client. `Ext` stays in every message as the
extension point ADR 0001 reserves, and `impl/v0` reads none.

**Each client defines its encoding:**

- **Tendermint**: the protobuf encoding of an ibc-go `MerkleProof`
  (`ibc.core.commitment.v1/v2`, `repeated cosmos.ics23.v1.CommitmentProof
  proofs = 1`), exactly what the counterparty's ABCI query returns, so a
  relayer passes it through. `ics23.UnmarshalMerkleProof` decodes it; its
  inverse `ics23.MarshalMerkleProof` serves tests and Gno callers.
- **Ethereum**: the wire encoding (`p/aib/encoding/wire`) of a
  `MembershipProof`, which `ethrelay` already received from the relayer;
  `DecodeMembershipProof` reads it and `MembershipProof.Encode` writes it.
  `ethrelay` now forwards the blob without decoding it.

**The protobuf decoder reads untrusted input**, so it is strict where
strictness costs nothing: it skips unknown fields as protobuf does, but
refuses a known field with the wrong wire type, a singular field set twice
(protobuf would merge or overwrite), a `CommitmentProof` naming more than one
proof, batch and compressed batch proofs (no IBC proof uses them), group wire
types, out-of-range enums, bad varints and lengths beyond the message. The
schema has no recursion, so its depth is fixed. Leniency would not threaten
correctness, since a decoded proof must still match the client's proof specs
and hash to its trusted root, but a strict decoder leaves fewer encodings to
reason about. Decoded byte fields share the input's backing array: the
proofs are verified and dropped, never stored.

`extproof` and `ics23.CheckProofs` are deleted.

## Alternatives considered

1. **Keep the typed proofs.** Keeps the relayer and the filetests as they
   were, and the decoding out of the VM. Rejected: it keeps the caller-code
   guard as an invariant every path must uphold, the two proof routes in the
   core, and a relayer that generates Gno source for each proof, all frozen
   at the first deploy.
2. **Wire-encode the Tendermint proofs too.** The wire reader is simpler
   than a protobuf decoder. Rejected: the relayer would decode the
   counterparty's protobuf and re-encode it with a second, custom encoder,
   for a format no other IBC implementation reads; protobuf keeps the bytes
   exactly as ibc-go produces and consumes them.
3. **Opaque bytes in the core only, typed proofs in the client interface.**
   The core would decode before calling the client. Rejected: the core would
   then have to know every client's proof format, which is what the light
   client abstraction exists to avoid.

## Consequences

Positive:

- No proof value carries code: the caller-supplied-implementation class is
  gone for proofs, without a guard to maintain.
- One verification path in the core for every client type; a new client type
  brings its own proof format without a signature change.
- The core's messages match ibc-go's, and a relayer passes the ABCI query's
  proof bytes through instead of generating Gno literals.
- `types` no longer depends on `ics23`.

Negative:

- A protobuf decoder in the Tendermint client is new code reading untrusted
  input. It is pinned by proofs ibc-go encoded (decoded, verified against the
  app hash and re-encoded byte for byte) and by malformed-input tests
  (`ics23` `TestMerkleProofIBCGoVectors`, `TestMerkleProofMalformed`,
  `TestMerkleProofUnknownFields`).
- Decoding runs in the VM and costs gas, in place of the `MsgRun`
  preprocessing of the proof's Gno literals; not measured yet.
- Breaking for the relayer: ts-relayer's Gno templates (`ProofHelper.ts` and
  the RecvPacket, AcknowledgePacket and TimeoutPacket templates) must embed
  the `MerkleProof` bytes instead of `ics23` literals, in the same release as
  the realms. The Ethereum relayer is unaffected: `ethrelay`'s wire format
  does not change.
- Filetests build ICS23 proofs as Gno literals still (`cmd/gen-proof` output)
  and pass `ics23.MarshalMerkleProof(proof)`.

## Open questions

- **Relaying the Tendermint route through `MsgCall`.** With every proof a
  byte string, the packet is the only structured argument left, and
  `ethrelay`'s packet reader is route-agnostic: a wire-encoded entry point for
  both routes would spare relayers `MsgRun` and its preprocessing gas. Left
  for a follow-up.
