# RecoverClient

`core.RecoverClient` is the governance escape hatch that revives a client that
has become unusable — either **Frozen** (valid misbehaviour was submitted via
`UpdateClient`) or **Expired** (no valid header was submitted within the
`TrustingPeriod`) — by copying state from a healthy **substitute** client that
tracks the same counterparty chain.

```gno
core.RecoverClient(cross, subjectClientID, substituteClientID string)
```

Only the admin can call it (see `admin.gno`). In the long run this is expected
to be driven by a govDAO proposal callback (tracked in issue #36).

## End-to-end flow

### 1. A client becomes unusable

- **Frozen**: a relayer submitted valid misbehaviour via `UpdateClient` (two
  conflicting signed headers for the same chain). The client's `FrozenHeight`
  becomes non-zero and `Status()` returns `Frozen`.
- **Expired**: no valid header was submitted within `TrustingPeriod`, so
  `Status()` returns `Expired` because the latest consensus state's timestamp
  is too old.

From this point `SendPacket`, `RecvPacket`, `Acknowledgement`, `Timeout` and
`UpdateClient` all panic for this client. Any in-flight user packets are
stuck, and any inbound packets cannot be acknowledged. Channels using this
client are frozen on this side until the client is recovered.

### 2. Off-chain coordination

Stakeholders agree to recover rather than migrate to a brand-new client.
Recovery is preferable because it preserves the client ID, packet
commitments / receipts / acknowledgements, counterparty registration and
channel state — users don't need to migrate anything.

### 3. Create a substitute client

A relayer calls `core.CreateClient` with a fresh, **Active** client targeting
the *same counterparty chain*. The substitute must satisfy
`isMatchingClientState` with the subject, i.e. these fields must match:

- `TrustLevel`
- `UnbondingPeriod`
- `MaxClockDrift`
- `ProofSpecs`
- `UpgradePath`

The following are allowed to differ and are **adopted from the substitute** by
the subject during recovery:

- `ChainID` (typically the same, but the code supports a change — for example
  a genesis-restart on a new chain ID tracking the same state). `ChainID` and
  `LatestHeight` are always adopted together, so their revision numbers stay
  aligned: `ClientState.ValidateBasic` requires
  `LatestHeight.RevisionNumber == ParseChainID(ChainID)`, and since both sides
  of that equality come from the substitute (which passed `ValidateBasic` at
  `CreateClient`), the invariant is preserved on the subject post-recovery.
- `LatestHeight`
- `TrustingPeriod` — this is the parameter-tweaking knob: if the original
  `TrustingPeriod` was set too aggressively (and partly caused the expiry),
  governance can choose a larger value on the substitute and that new value is
  copied into the subject. Same mechanism as ibc-go.
- `FrozenHeight` (always reset to zero)

### 4. (Optional) Fast-forward the substitute

Relayers call `UpdateClient(substituteID, header)` until the substitute's
`LatestHeight` is at the desired recovery height. The substitute must be
`Active` at the moment recovery executes.

### 5. Governance proposal

A proposal asks to run:

```gno
core.RecoverClient(cross, subjectID, substituteID)
```

Currently gated by `ensureAdminCaller()`; once govDAO integration lands the
proposal executor becomes the authorized caller.

### 6. `RecoverClient` executes

`r/aib/ibc/core/client.gno`:

1. `ensureAdminCaller()`.
2. Subject and substitute IDs must differ; both must resolve; `typ` must match.
3. Subject status ∈ {`Frozen`, `Expired`}; substitute status must be `Active`.
4. Delegates to `subject.lightClient.RecoverClient(substitute.lightClient)`.

`p/aib/ibc/lightclient/tendermint/tendermint.gno`:

1. Type-assert substitute to `*TMLightClient`.
2. `isMatchingClientState` check.
3. Fetch `substitute.GetConsensusState(substitute.LatestHeight)`.
4. Copy into subject: `ChainID`, `LatestHeight`, `TrustingPeriod`; reset
   `FrozenHeight`.
5. Store the substitute's consensus state at the substitute's latest height in
   the subject.

### 7. Post-recovery state

- Subject's `Status() == Active`. `UpdateClient`, packet verification, etc.
  resume.
- **Packet commitments, receipts, acknowledgements, `sendSeq`,
  `counterpartyClientID`, `counterpartyMerklePrefix` are untouched** — that is
  the point: channels keep working with their existing identifiers and
  in-flight state.
- Pre-recovery consensus states remain in the subject's tree but are below the
  new `LatestHeight` and are not used to verify new packets.
- The substitute client is **not** deleted and remains `Active`. It can be
  reused for a future recovery or left idle.
- `recover_client` event is emitted.

### 8. Counterparty side (symmetric)

If the counterparty chain's client tracking this chain is also Frozen/Expired
(common when misbehaviour or a long halt affects both sides), the counterparty
runs its own governance-level recovery. Packet relaying cannot resume on that
path until both sides are `Active`.

### 9. Relayer resumes

Once both sides are `Active`, relayers submit headers via `UpdateClient` and
the normal packet lifecycle resumes. No re-`RegisterCounterparty`, no new
channel.

## Changing parameters during recovery

Because the substitute's `TrustingPeriod` and `ChainID` are adopted by the
subject, creating the substitute is also the opportunity to adjust those
parameters through the same governance action:

- **Lengthening `TrustingPeriod`** to reduce the risk of future expiry — for
  example after learning that the counterparty's block production is slower
  than originally assumed.
- **Adopting a new `ChainID`** after a counterparty genesis restart that kept
  the same consensus state tree — the subject starts verifying headers signed
  under the new chain ID without being migrated to a new client ID.

Other parameters (`TrustLevel`, `UnbondingPeriod`, `MaxClockDrift`,
`ProofSpecs`, `UpgradePath`) **cannot** be changed by recovery — the match
check rejects the substitute. Changing those requires `UpgradeClient` (or a
fresh client migration).

## Caveats

- The substitute's `LatestHeight` is not required to be greater than the
  subject's. Same as ibc-go — nothing enforces a "forward" recovery, though in
  practice the substitute is always ahead.
- Only the substitute's consensus state **at its `LatestHeight`** is copied
  into the subject. Earlier substitute consensus states are not migrated.
- Recovery does not reset packet sequences or clear commitments — those are
  packet-layer concerns and stay intact.
