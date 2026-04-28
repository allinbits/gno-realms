# UpgradeClient

`core.UpgradeClient` follows a counterparty chain through a **breaking**
upgrade — an upgrade that `UpdateClient` cannot absorb because the chain
itself changes shape. Typical triggers:

- `ChainID` change (signed in every header).
- Revision-number bump (encoded in `Height`, propagates into header
  signing).
- Validator-set discontinuity (a hard fork that doesn't preserve the
  trust graph).
- Security-parameter changes the client carries — `UnbondingPeriod`,
  `ProofSpecs`, `UpgradePath`.

```gno
core.UpgradeClient(cross, clientID,
    upgradedClient, upgradedConsState,
    proofUpgradeClient, proofUpgradeConsState)
```

Gated by `ensureAuthorizedRelayer()`.

## Lifecycle

### 1. Counterparty schedules the upgrade

Before the upgrade height the counterparty chain commits the upgraded
`ClientState` and `ConsensusState` to its upgrade store at well-known
paths derived from the client's `UpgradePath` (the SDK upgrade module
default is `["upgrade", "upgradedIBCState"]`):

- `{UpgradePath[0]}/{UpgradePath[1]}/{H}/upgradedClient`
- `{UpgradePath[0]}/{UpgradePath[1]}/{H}/upgradedConsState`

`H` is the upgrade plan height (just the height number, not a revision
pair). The committed bytes are `cdc.MarshalInterface(...)`-style:
wrapped in `google.protobuf.Any` with the corresponding type URL.

The committed `ClientState` has its client-customizable fields
(`TrustLevel`, `TrustingPeriod`, `MaxClockDrift`, `FrozenHeight`) zeroed
out — only the chain-specified fields (`ChainID`, `UnbondingPeriod`,
`LatestHeight`, `ProofSpecs`, `UpgradePath`) are committed. The
committed `ConsensusState` carries a sentinel `Root` because the
upgraded chain hasn't produced any blocks yet at commit time.

### 2. Relayer reads and submits

Once the chain has reached the upgrade height, a relayer reads the
committed states and the corresponding ICS-23 membership proofs and
calls `UpgradeClient`. Each proof is a chained `[]ics23.CommitmentProof`
matching the client's `ProofSpecs` (typically 2 proofs: an IAVL
existence proof for the inner key and a multistore existence proof for
the store name).

### 3. Verification

The realm checks:

- `UpgradePath` on the current client is non-empty.
- `LatestHeight` of the upgraded client is greater than the current
  latest height.
- The relayer's submitted client/consensus states reconstruct the bytes
  the chain committed: the `ClientState` is wrapped in
  `google.protobuf.Any` with its customizable fields zeroed
  (`ZeroCustomFields`), the `ConsensusState` is wrapped in `Any` as-is.
- Both chained proofs verify membership under the current client's
  latest consensus root.

### 4. State transition

A new `ClientState` is built by mixing fields (see below). The stored
consensus state has its `Root` overwritten with the sentinel value so it
cannot be used to verify packet proofs — by construction. Real roots
arrive afterwards via `UpdateClient` once the new chain is producing
headers.

### 5. Resume

Subsequent `UpdateClient` calls bring real headers from the new chain;
packet flow resumes against those real consensus states.

## Preconditions

- The client exists and the caller is in the relayer whitelist.
- The client's `UpgradePath` is set.
- The client's status is `Active`.
- The upgraded client's `LatestHeight` is greater than the current
  latest height.
- Both proofs verify membership of the upgraded client and consensus
  state at the upgrade path under the current latest consensus root.

## Field mapping

On success the new `ClientState` is built by combining:

- **Taken from the upgraded client** (chain-specified): `ChainID`,
  `UnbondingPeriod`, `LatestHeight`, `ProofSpecs`, `UpgradePath`.
- **Preserved from the current client** (customizable): `TrustLevel`,
  `TrustingPeriod`, `MaxClockDrift`.
- **Reset**: `FrozenHeight`.

If the unbonding period shrank, `TrustingPeriod` is scaled
proportionally so the security ratio is preserved:

    newTrusting = trusting * newUnbonding / currentUnbonding (truncated)

The math is performed in seconds; sub-second precision is irrelevant for
trusting periods which are measured in days.

## Generating proofs for testing

`cmd/gen-proof` provides an `upgrade` subcommand that mounts an
`upgrade` IAVL store, commits the upgraded client/consensus state at
the SDK upgrade keys (`upgradedIBCState/{H}/upgradedClient`,
`upgradedIBCState/{H}/upgradedConsState`), and dumps Go literals for the
chained proofs:

```bash
go run -C ./cmd/gen-proof . upgrade
```

The output is suitable for embedding in a filetest. See
`z10c_upgrade_client_filetest.gno` for the full happy-path scenario.
