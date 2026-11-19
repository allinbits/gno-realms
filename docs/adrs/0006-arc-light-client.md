# ADR 0006: Arc light client

- Status: Proposed
- Date: 2026-11-03

## Context

[Arc](https://github.com/circlefin/arc-node) is Circle's EVM L1. Its
consensus layer is Malachite (circlefin's fork of informalsystems/malachite,
tag v0.8.0), a Tendermint BFT engine, driving a Reth execution layer through
the Engine API. The question was whether IBC v2 between gno.land and Arc can
reuse what exists for Ethereum:

- **On Arc**, the Solidity side of gno-eth-ibc (solidity-ibc-eureka's ICS26
  router, the ICS20 fork with route controls, `GnoLightClient.sol`) is EVM
  code that does not depend on Ethereum's consensus, and gno.land's
  secp256k1 validators (gnolang/gno#6375) are verified with `ecrecover`,
  which Arc has. It deploys unchanged.
- **On gno.land**, a light client of Arc is needed. Malachite finality is
  Tendermint's (single-round BFT, a commit certificate of more than 2/3 of
  the voting power, final forever), so the client should be a variant of
  07-tendermint; Arc's state is the EVM's, so packet proofs are the same
  `eth_getProof` storage proofs the Ethereum client checks.

Everything below about Arc was read from arc-node and malachite at HEAD on
2026-11-03 and checked against the live testnet (chain id 5042002).

## What a certificate proves

`arc_getCertificate(height)` returns Malachite's `CommitCertificate`
(`malachite/code/crates/core-types/src/certificate.rs`): height, round, value
id and the precommit signatures `(address, signature)`.

- The value id is the **EVM block hash**
  (`arc-node/crates/types/src/value.rs`, `ValueId(BlockHash)`):
  `keccak256(rlp(header))`, which commits to the state root. The live
  certificate of block 70498732 names `eth_getBlockByNumber(70498732).hash`.
- A precommit signs, with **Ed25519** (`ed25519-consensus`, ZIP-215), the SSZ
  encoding of arc-node's `Vote` without its extension
  (`crates/types/src/vote.rs`, `to_sign_bytes`), with no hash, domain tag or
  **chain id**: 75 bytes, `type (1 = Precommit) | height u64 LE | offset 37 |
  offset 42 | address (20) | 0x01 round u32 LE | 0x01 block hash (32)`
  (`certificate.gno`, pinned by `TestPrecommitSignBytes` against a live
  precommit). gno's `crypto/ed25519` native verifies it.
- A validator's address is the **first** 20 bytes of `keccak256(pubkey)`
  (`crates/types/src/address.rs`), not the last as for Ethereum accounts.
- Quorum is `signed*3 > total*2` (Malachite `threshold.rs`), each address at
  most once.

## Where the validator set is

Not in the header: the consensus layer calls
`ValidatorRegistry.getActiveValidatorSet()` (proxy
`0x3600000000000000000000000000000000000002`) on the state after block H-1
to get the set for height H (`crates/eth-engine/src/rpc/ethereum_rpc.rs`,
`get_signing_validator_set`), and keeps the entries with status Active and
positive power (`abi_utils.rs`). The client reads the same entries from the
registry's storage (ERC-7201 base
`0xb58d…d200`): the active registrations' `EnumerableSet` at S+1, and for each
id the `Validator{status, publicKey, votingPower}` at
`keccak256(abi.encode(id, S))` (`registry.gno` documents the layout). The
relayer sends one pool of storage-trie nodes for all of those slots (and the
proxy's implementation slot); the client computes every key itself. On the
testnet (22 active registrations, 21 of them with power; 112 slots) the pool
is 164 nodes, about 16 KB.

The consensus layer also drops a registration whose key does not decode to
an Ed25519 point (`try_decode_validator`, through `ed25519_consensus`'s
`VerificationKey::try_from`), while the registry only checks a key's length.
The client drops the same keys (`point.gno`: the decompression succeeds when
`(y²-1)/(d·y²+1)` is a square mod p, decided by Euler's criterion with the
`crypto/modexp` native). Kept, such a key could never sign but would count in
the total power, and could stall the client for good.

## Decision

`gno.land/p/aib/ibc/lightclient/arc/v0`, client type `arc`, ids `arc-N`,
heights `{0, block number}`.

**Consensus state** of a block B: height, timestamp (seconds), block hash,
state root, the registry's storage root in B's state, and `NextValidators`,
the set B's state holds: the set that signs B+1.

**Update** (`Header`) from the latest trusted block T to a block B > T,
using the certificate of B's child C = B+1:

1. C's RLP header hashes to the certificate's block hash and has its height;
   B's RLP header hashes to C's parent hash. A certified block's parent is
   final (every ancestor of a final block is).
2. The registry's account proof in B's state gives its storage root. Equal
   to T's: the set is T's (`NextValidators` shared, no set proof). Otherwise
   the set is read from the node pool; a set read equal to T's, the same
   validators with the same powers in any order (the registry's storage
   can change without its active set changing, and a removal reorders it;
   signatures are matched by address, so the order certifies nothing), is
   T's set: shared as stored, and step 3's trust-level check does not
   apply to it (`TestSyntheticIdleSharesSet`, `TestSyntheticIdleNoTrustCheck`,
   `TestSyntheticReorderNoTrustCheck`). Only a different set is copied and
   stored: a set is stored once per change.
3. That set (B's, which signed C) must have signed more than 2/3; when it is
   not T's set, more than the trust level (default 1/3) of T's set must have
   signed C too: Tendermint's skipping verification. Each signature is
   verified once. Each set's share is counted by its own powers, a
   rotated-out validator's signature still counting for T's
   (`TestSyntheticRotationTrustLevel`, `TestSyntheticReweight`,
   `TestSyntheticTrustLevelParameter`: T's share below, exactly at and
   above the level, B's set at and below 2/3).
4. B's timestamp is not before T's and not past `now + MaxClockDrift`; T is
   within the trusting period.

**Why B and not C.** Arc's public RPC nodes serve `eth_getProof` for the
latest block only (blockdaemon: "distance to target block exceeds maximum
proof window" at depth 1; drpc: "Unknown state" for any number). An update
that needed proofs at both H-1 (the signing set) and H could not be built
from them. Proving B, the set B's state holds signs B+1, so every proof of an
update (the registry's and the packet commitments') is into one state, read
while B is the latest; the relayer then waits for C's certificate (blocks are
about 0.5 s). `relayer/arc` identifies B by the account proof's root and
retries when the chain moves between proof calls.

**Membership** proofs are `ethereum.MembershipProof` in the `Ext` field,
checked by the Ethereum client's MPT code against the consensus state's
state root (`ethereum.RouterCommitment`). That code is exported from the
Ethereum package (`evm.gno`) rather than copied; `mptGet` gained a variant
over an indexed node pool (`StorageReader`). A proof is refused for any
other value, path, state root, router, commitment slot or height than its
own (`TestSyntheticMembership`, `TestSyntheticMembershipRefusals`), and
after a recovery for any height below the substitute's
(`TestSyntheticProofsAfterRecovery`): those states were trusted by the
client state the recovery replaced. A proof is also refused at a height
whose state is `TrustingPeriod` seconds old or more, whether or not that
state was pruned yet (`TestProofRefusedPastTrustingPeriod`).

**Pruning**, as the Ethereum client does (ADR 0003, gno-realms#96): each
update removes
the oldest consensus state if no proof can use it any more, one below a
recovery's cut-off or past the trusting period, so the store converges to
about one trusting period of states and the deposit of the removed bytes
is refunded to the updater. `PruneExpiredConsensusStates(limit)` removes up
to `limit` such states in one call, for a client that accumulated them
before (from a later core implementation's `OnInstall` migration, as for
the Ethereum client); the core exposes no entry point for it. The latest state is never removed: `Status`, recoveries
and renders read it. A set shared by consensus states stays stored while
any of them does.

**Storing the set, not its hash.** Tendermint's client stores a hash of the
next validator set because its header commits one and carries the set
anyway. Arc's blocks commit to no hash of the set, so with a stored hash
the relayer would send the full set (a 32-byte key and a power per
validator: about 1 KB at Arc testnet's 21, up to about 10 KB at
`MaxValidators`) and the client would decode and hash it on
every update, the usual unchanged-registry one included, which today sends
none (about 15M gas). Storing it costs one deposit per set change, which
pruning refunds once no state holds it.

**The registry's implementation is pinned.** The client reads the set by the
layout of the registry implementation it was created with: creation reads the
proxy's ERC-1967 implementation slot from the same node pool and records it
(`ClientState.RegistryImplementation`); every later set read requires the
proxy to still name it. An upgrade that moved the registry's storage to a new
namespace would otherwise leave the client reading a stale set at the old
location, which the old keys could keep signing for. After such an upgrade
the client stops at its next set read, and a governed recovery from a client
created after the upgrade moves it on: a recovery adopts the substitute's
implementation and storage location (`TestTestnetRecoveryAdoptsLayout`). A
new location is all a recovery can follow; an upgrade that changed the
`Validator` struct or the set's encoding needs a new version of this client.

**Bounds.** At most 256 active registrations (Arc has none; past it the
client stops at its next set change); total power at most 2^62, the trust
check multiplying in 128 bits. Both are checked when a set is read and again
by `ConsensusState.ValidateBasic` on a created one, whose sum is checked
before each addition so that it cannot wrap (`TestValidatorSetValidateBounds`); trust level in [1/3, 1) (the check is "more
than", which nothing passes at 1); `MaxClockDrift` at most an hour and
`TrustingPeriod` at most a year. The relayer's default drift is 90 seconds:
Arc's validators accept a proposer's timestamp up to 30 seconds ahead
(`skew_gate.rs`), and gno.land's block time trails real time.

**Other rules**, as the Ethereum client: updates and misbehaviour must build
on the latest trusted height; misbehaviour is two headers proving different
blocks at one height; a recovery copies a substitute tracking the same chain
id, registry address and router (the route identity, `RouteIdentity`), with
a valid client state, and adopts its registry implementation and storage
location; no IBC upgrade path. The substitute may be a later verifier
version wrapping arc/v0: recoveries and the core's renders read the v0
state through `Arc()`, as the Ethereum client's do through `Ethereum()`
(`TestTestnetRecoveryFromLaterVersion`). The renders treat a verifier that
keeps no arc/v0 state as the Ethereum ones do, instead of panicking: the
consensus-state routes return an error, and the client route leaves out
the client and consensus state. The chain alone, its id and registry address, is `ChainIdentity`:
ibcgov keeps one route per counterparty chain (ADR 0007), whatever its
router.

**Integration.** The core records, when it creates a client, whether its
counterparty is an ICS26 router on an EVM chain (`Client.IsRouter`,
`core.IsRouterClient`); `core impl/v0` `CreateClient` records an Arc client
as one, as it does an Ethereum client, and nothing else changes for the
applications. The router flag selects the router client-id grammar and empty
merkle prefix (`RegisterCounterparty`), `ValidateBasicRouter` packets,
ABI-encoded ICS20 payloads and the route controls (transfer
`impl/controls/v0` `isRouter`). Arc adds it in three places that still
compared the client type with Ethereum's: permissionless relaying (`core`
`ensureRelayerFor`), ibcgov route enrolment and flags, and the governance
channel (`ibcgov` `checkBindClient`, `checkLocal`), which still binds one
counterparty IBCAdmin per chain, Ethereum's or Arc's, whichever the chain's
route goes to. What stays Ethereum-only: fork-schedule migrations and
verifier replacements (`core impl/v0`, ibcgov `core migrate client`). `r/aib/ibc/ethrelay` gains
`CreateArcClient`, `UpdateArcClient` and `SubmitArcMisbehaviour`; its packet
functions serve both chains (same proof format).

**Test data.** The testnet fixture (`arc/testing/v0`, a test helper that
`scripts/packages.sh` does not deploy, recorded by
gno-eth-ibc's `relayer/cmd/arc-fixtures`) gives a creation and an update
whose set did not change, and no commitment proofs. The rest comes from
synthetic data (`zz_synthetic_test.gno`, written by `cmd/gen-arc-synthetic`;
`go test -C cmd/gen-arc-synthetic` checks that the committed file is what it
writes): a chain whose blocks 100, 110, 120 and 130 have full states, the
registry holding a trusted set at 100, a rotated set at 110 (two validators
out, two in, every kept power changed), the same validators with other
powers at 120, at 130 the trusted set under another storage root (a
powerless registration deactivated) and at 140 the trusted set in another
order (a validator deactivated and registered again), each update's
certificate signed by every key so that a
test picks the signers; and the router's commitments with proofs of two
packets and of the absence of a third. The generator builds everything from
Arc's and Ethereum's definitions, not from the client's code: RLP headers,
Merkle-Patricia tries (checked against ethereum/tests vectors), the
registry's Solidity storage layout (the ERC-7201 namespace, the
`EnumerableSet`'s swap-and-pop order, the ERC-1967 slot), the SSZ vote
(checked against the live precommit `TestPrecommitSignBytes` pins), with
Ed25519 keys from a fixed seed, since Gno cannot sign.

## Consequences

- **No chain id in votes.** What pins a client to one Arc network is its
  trusted validator set, from creation on: a client created with a testnet
  set could accept devnet blocks signed by the same keys. Creation is
  trusted, as for every IBC client; `ChainID` is recorded for the route
  identity only.
- **The registry layout is a trust assumption.** The client mirrors
  `getActiveValidatorSet()` and the consensus layer's filter from storage,
  for the pinned implementation. A storage root equal to the trusted one
  proves the same set because the proxy's implementation slot is in the same
  storage and contract code cannot change (EIP-6780). A change of the filter
  in the consensus layer (arc-node) itself would not be seen.
- **No accountability.** Arc is permissioned, with no unbonding or slashing:
  `TrustingPeriod` only bounds how long rotated-out keys keep the client's
  trust while no update brings it past the rotation, and should be short.
- **A large rotation in one block stalls the client.** An update proves a
  block B by the certificate of B+1, which B's own set signs; the trusted
  state pins no next set (Arc's header commits to none), so when B's set is
  not the trusted one more than the trust level of the trusted set must sign
  too, adjacent blocks included. A single block that replaces more than
  (1 - trust level) of the voting power leaves no update that verifies, and
  only a governed recovery moves the client on (the rotation of
  `TestSyntheticRotationTrustLevel` signed by too little of the trusted
  set). Verifying B's certificate by the trusted set first would remove
  this, at the price of a second certificate per update; not done while
  Arc's set is permissioned and rotates a validator at a time.
- **No evidence after a successful attack.** Misbehaviour must build on the
  latest height: once a forged header (signed by more than the trust level
  of the trusted set) is the latest, evidence against it cannot be
  submitted, and recovery depends on governance noticing.
- **Gas** (GnoVM gas in gno test runs, testnet data, 21 validators):
  creation, which reads the set, about 206M; an update with an unchanged
  registry about 15M (about 15 Ed25519 signatures, two RLP headers, one
  account proof): Tendermint's order of cost; an update reading the set
  about 171M. Reading the set is the price of a set that no header commits
  to: 112 storage slots, each a Merkle-Patricia walk of 7 to 8 nodes in
  interpreted Gno, plus the point check (about 2.6M per key, run again by
  `ValidateBasic` on a created set). Two things keep it there: the node pool
  decodes each trie node once (the slots' paths share their top levels;
  before, every walk decoded them again: 670M), and `UpdateState` reuses
  what `VerifyClientMessage` derived, kept on the header (set through a
  method, as the core holds the header readonly), instead of reading the
  proofs a second time. Ethereum updates cost 250M to 400M.
- **ZIP-215.** Arc accepts Ed25519 signatures by ZIP-215 rules; gno's native
  is Go's `crypto/ed25519`, stricter on non-canonical encodings. An honest
  signature verifies under both; at worst a certificate with an edge-case
  signature fails here (liveness, not safety): a relayer can omit that
  signature when the rest still exceeds 2/3.
- **Routes.** Under ADR 0007 ibcgov governs one route per counterparty
  chain, so an Arc route runs beside an Ethereum one, each with its own
  governance channel and IBCAdmin. Until ADR 0007's change lands, ibcgov
  enrolls one router route in total (`checkOneRoute`) and an Arc route
  replaces the Ethereum one. A router client of no enrolled route carries
  no transfers (the route controls refuse it).

## Alternatives considered

- **Prove the signing set at H-1 and the packet state at H**, storing H: the
  natural Tendermint shape, but it needs two historical states per update,
  which Arc's public RPCs do not serve.
- **Carry the validator set in the message and trust its hash**: there is no
  hash of the set in Arc's header or certificate to check it against; only
  the registry's state is committed.
- **Read the set through `eth_call` results**: not provable; storage proofs
  are.
- **Copy the MPT code into the Arc package**: about 300 lines duplicated from
  the Ethereum client; exporting it keeps one implementation.
