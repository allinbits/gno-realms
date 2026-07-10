# AGENTS.md

IBC v2 implementation for Gno (similar to IBC Eureka for Ethereum). Gno smart contracts ("realms" and "packages") enabling cross-chain communication via the Inter-Blockchain Communication protocol.

## Build & Test Commands

```bash
make test           # Run all tests (gno filetests + Go tests)
make gnodev         # Start local gno node with all realms/packages
make update-fork    # Re-pin gnolang/gno to FORK_REF (branch/tag/commit; default: pinned commit)
make mod-download   # Sync gno package cache (~/.config/gno/pkg/mod/) with the pinned commit
```

CI runs unit + e2e tests on every push (`.github/workflows/test.yml`).

Under the hood:
- `go tool gno test ./gno.land/...` runs all Gno tests (unit tests + filetests)
- `go test -C ./cmd/gen-block-signatures` and `go test -C ./cmd/gen-proof` run Go tests

**Important:** Always use `go tool gno test`, not a standalone `gno` binary. The pinned `gnolang/gno@master` commit is resolved via `go mod` replace directives, so `go tool gno` picks up the correct version automatically. A standalone `gno` may be a different (older) release and miss features the realms rely on.

**Important:** After `make update-fork`, run `make mod-download` to sync the gno package cache (`~/.config/gno/pkg/mod/`) with the pinned commit. The gno toolchain resolves realm/package dependencies from this cache, not from the Go module cache. Without `mod-download`, tests may use stale versions of dependencies.

Run a single package's tests:
```bash
go tool gno test ./gno.land/p/aib/ibc/types
```

Run a specific test by name:
```bash
go tool gno test -run TestPacketValidateBasic ./gno.land/p/aib/ibc/types
```

Run a single **filetest**: `-run` must match the full path to the test file,
not just its name. A bare prefix like `-run z5a_` silently matches nothing (the
run reports `ok` without executing the filetest); the pattern has to start with
the package path:
```bash
go tool gno test -run ./gno.land/r/aib/ibc/apps/transfer/z5a_ ./gno.land/r/aib/ibc/apps/transfer/
```

Update filetest golden output (`// Output:` and `// Events:` sections) automatically:
```bash
go tool gno test -update-golden-tests ./gno.land/r/aib/ibc/apps/transfer/
```

## Architecture

### Directory Layout

```
cmd/                          # Go CLI tools
  gen-block-signatures/       # Generate Tendermint block signatures for test headers
  gen-proof/                  # Generate IBC proof structures
gno.land/
  p/aib/                      # Packages (stateless libraries)
    ibc/app/                  # IBCApp interface definition
    ibc/types/                # Core types: Packet, Height, Msgs, Payload
    ibc/host/                 # ICS-024 identifier validation, packet key generation
    ibc/lightclient/          # Light client interface (12 methods)
    ibc/lightclient/tendermint/         # Tendermint light client implementation
    ibc/lightclient/tendermint/testing/ # Test helpers: NewMsgHeader, GenValset, etc.
    ibc/testing/              # ICS-23 proof test helpers
    ics23/                    # ICS-23 Merkle proof verification
    encoding/                 # Uint64 big-endian encoding
    encoding/proto/           # Protobuf varint/field encoding
    merkle/                   # RFC-6962 Merkle tree
    jsonpage/                 # AVL tree JSON pagination
  r/aib/ibc/                  # Realms (stateful contracts)
    core/                     # IBC v2 core: CreateClient, SendPacket, RecvPacket, etc.
    apps/transfer/            # Token transfer app (ICS-20 equivalent)
    apps/testing/             # Mock IBCApp for tests
```

### Key Interfaces

**IBCApp** (`p/aib/ibc/app/app.gno`): Apps must implement 4 callbacks:
- `OnSendPacket`, `OnRecvPacket`, `OnTimeoutPacket`, `OnAcknowledgementPacket`
- Register apps with `core.RegisterApp(cur, portID, app)`

**lightclient.Interface** (`p/aib/ibc/lightclient/lightclient.gno`): 12 methods including `Initialize`, `VerifyClientMessage`, `UpdateState`, `VerifyMembership`, `VerifyNonMembership`, `Status`, `LatestHeight`

### IBC v2 Packet Lifecycle

1. **CreateClient** + **RegisterCounterparty** - setup phase
2. **SendPacket** - validates, stores commitment, calls app `OnSendPacket`
3. **RecvPacket** - verifies proof, calls app `OnRecvPacket`, stores acknowledgement
4. **Acknowledgement** - verifies ack proof, calls app `OnAcknowledgementPacket`, clears commitment
5. **Timeout** - verifies non-membership proof, calls app `OnTimeoutPacket`, clears commitment

Core functions use `panic()` for errors (no return errors from realm entry points).

## Gno-Specific Conventions

### Module Manifests (gnomod.toml)

Each package/realm has a `gnomod.toml` (not `gno.mod`):
```toml
module = "gno.land/r/aib/ibc/core"
gno = "0.9"
```

- `p/` = packages (stateless, reusable libraries)
- `r/` = realms (stateful contracts with persistent storage)

### The `cur realm` and `cross` Keywords (interrealm v2 / gno 0.9)

Realm functions that need caller context take a `cur realm` first parameter:
```gno
func CreateClient(cur realm, clientState lightclient.ClientState, ...) string
```

Since the gno 0.9 interrealm change, **`cross` is a function** (`func cross(rlm realm) realm`), not a bare keyword. A cross-realm call applies `cross` to the current realm and passes the result as the first argument:
```gno
clientID := core.CreateClient(cross(cur), clientState, consensusState)
```
(The pre-0.9 form `core.CreateClient(cross, ...)` no longer compiles — `cross` used as a value panics with "cannot call non-function" / type errors.)

A non-crossing helper called within the same realm takes `cur` directly (no `cross`), e.g. `writeRecvPacketAcknowledgement(0, cur, packet)`. The leading `0 int` is the conventional discriminator for the non-crossing `(_ int, rlm realm, …)` helper form used by grc20/banker APIs.

The `realm` value exposes ACL predicates used throughout the realms:
`cur.Address()`, `cur.PkgPath()`, `cur.Previous()`, `cur.IsUserCall()`, `cur.IsCurrent()`. The guard `cur.Previous().IsUserCall()` (true only for a direct `maketx call` from an EOA) gates value-moving entry points like `Transfer`.

### MsgRun vs MsgCall

Most IBC functions require `MsgRun` (not `MsgCall`) because they take complex arguments (structs, slices of bytes). See `gno.land/r/aib/ibc/core/README.md` for examples.

### Gno Standard Library

- `chain/banker` - coin manipulation interface; `banker.NewBanker(banker.BankerTypeRealmSend, rlm)` now requires the realm capability
- `chain.Emit(eventType, kvPairs...)` - event emission
- `chain/runtime/unsafe` - caller context: `unsafe.OriginCaller()`, `unsafe.OriginSend()`, `unsafe.PreviousRealm()`, `unsafe.CurrentRealm()`. In interrealm v2 these moved out of `runtime` into `chain/runtime/unsafe` (the package is *named* `unsafe`, import path `chain/runtime/unsafe` — unrelated to Go's `unsafe`). Prefer the `cur realm` value's methods (`cur.Previous()`, `cur.IsUserCall()`) where caller context is available; reach for `unsafe.*` only for tx-level EOA identity (e.g. EOA-bound admin/relayer auth, packet `Sender`).
- `gno.land/p/nt/bptree/v0` - B+ tree (primary key-value storage)
- `gno.land/p/nt/seqid/v0` - monotonic ID generation
- `gno.land/p/nt/ufmt/v0` - string formatting
- `gno.land/p/nt/urequire/v0` / `gno.land/p/nt/uassert/v0` - test assertions

## GRC20 Voucher Tokens

IBC voucher tokens (minted on RecvPacket for cross-chain tokens) use **GRC20 tokens** instead of native banker coins. This enables DeFi compatibility (Gnoswap, etc.) via the `grc20reg` registry.

### Key Dependencies
- `gno.land/p/demo/tokens/grc20` - GRC20 token implementation. Interrealm v2 added a realm capability to the value-moving APIs: `grc20.NewToken(0, rlm, name, symbol, decimals)`, `token.RealmTeller(0, cur)`, and `teller.TransferFrom(0, cur, from, to, amount)` all take the `(_ int, rlm/cur realm, …)` non-crossing form. `PrivateLedger.Mint/Burn` move tokens without a realm arg.
- `gno.land/r/demo/defi/grc20reg` - Global token registry (`Register(cross(cur), token, slug)`, `Get`)

### How It Works
- **OnRecvPacket (mint)**: `getOrCreateGRC20(ibcDenom, baseDenom)` creates a GRC20 token + registers in grc20reg, then `inst.ledger.Mint(receiver, amount)`
- **OnSendPacket (burn)**: `getGRC20(ibcDenom)` retrieves the token, then `inst.ledger.Burn(sender, amount)`
- **Refund (ack error / timeout)**: `getGRC20(ibcDenom)` + `inst.ledger.Mint(sender, amount)` to re-mint

### What Uses Native Banker
- **Escrow/unescrow** of native tokens (ugnot, etc.) still uses `chain/banker`
- `Transfer()` is the only valid entry point for native coin transfers. It verifies the user attached the matching `-send` via `unsafe.OriginSend()` guarded by `cur.Previous().IsUserCall()`. The `IsUserCall` guard is what makes `OriginSend()` trustworthy — it ensures the coins actually landed at this realm, not at an intermediate code realm that forwarded the call. The verified coin is handed off to `OnSendPacket` through a package-level pointer (`pendingNativeEscrow`) cleared by a `defer` in `Transfer` so it never leaks across txs. `OnSendPacket` doesn't re-read `OriginSend()` because its previous realm is the core realm and the guard would always fail there; relying on the upstream `Transfer` check is structurally simpler than re-deriving it.

### Voucher Render Endpoints
- `voucher/ibc/{hash}` - Token info (name, symbol, total supply)
- `voucher/ibc/{hash}/balance/{address}` - Balance of an address

## Gno Dependency Management

This project tracks upstream **`gnolang/gno@master`**, pinned to a specific commit via `go mod replace` directives in `go.mod` (the `require` line stays at an older tagged release; the replace overrides it with the master commit):

```
github.com/gnolang/gno => github.com/gnolang/gno@<commit-hash>
github.com/gnolang/gno/contribs/gnodev => github.com/gnolang/gno/contribs/gnodev@<commit-hash>
```

The target repo and ref are set by `FORK_REPO`/`FORK_REF` in the `Makefile` (`FORK_REF` defaults to a pinned commit). `FORK_REF` accepts a **branch name, tag, or commit hash** and is used in two places: `make update-fork` passes it straight to `go mod edit -replace` and `go mod tidy` resolves it to a pseudo-version and rewrites the replace directives (run `make mod-download` afterward to sync the gno package cache); the e2e gno image build (`e2e/gno/Dockerfile`) shallow-fetches the same ref via `git fetch`. Examples: `make update-fork` (re-pin the default), `make update-fork FORK_REF=master` (track latest master), `make update-fork FORK_REF=<commit>`. (The historical project required a fork for IBC features; those now live in upstream master, hence the `gnolang/gno => gnolang/gno` self-replace pinning a recent commit.)

## Testing Patterns

### Filetests (primary test mechanism)

Files live in a `filetests/` subdir of each realm (e.g. `gno.land/r/aib/ibc/core/filetests/`), named `z*_filetest.gno`, and start with a `// PKGPATH:` directive (required by `-update-golden-tests`). They run as standalone `package main` programs with expected output matching. Under interrealm v2, `main` takes a `cur realm` parameter and cross-realm calls use `cross(cur)`:

```gno
// PKGPATH: gno.land/r/aib/main
package main

import "gno.land/r/aib/ibc/core"

func main(cur realm) {
    clientID := core.CreateClient(cross(cur), clientState, consensusState)
    println("CreateClient", clientID)
}

// Output:
// CreateClient 07-tendermint-1

// Events:
// [{"type": "create_client", "attrs": [...]}]
```

Naming convention: `z{category}{letter}_{description}_filetest.gno`

**core realm**: `z1*` = create client, `z2*` = update client, `z3*` = send packet, `z5*` = acknowledgement, `z6*` = timeout, `z7*` = recv packet, `z8*` = misbehaviour

**transfer app**: `z0*` = init, `z1*` = send packet, `z2*` = ack packet, `z3*` = timeout, `z4*` = recv packet, `z5*` = Transfer function. Double letters (e.g. `z1aa`) = IBC voucher token variant (vs `z1a` = native token)

`zz_*_example_filetest.gno` = documentation examples (referenced from README)

### Unit Tests with Malleate Pattern

`*_test.gno` files use table-driven tests with a `malleate` function that mutates a default valid object to test specific conditions:

```gno
testCases := []struct {
    name     string
    malleate func()
    expErr   string
}{
    {"success", func() {}, ""},
    {"failure: empty field", func() { msg.Field = "" }, "field required"},
}
for _, tc := range testCases {
    t.Run(tc.name, func(t *testing.T) {
        msg = newValidMsg()    // reset to valid defaults
        tc.malleate()          // apply mutation
        err := msg.Validate()
        // assert error
    })
}
```

### Test Helper Packages

- **`p/aib/ibc/lightclient/tendermint/testing`** - `NewClientState()`, `GenValset()`, `GenConsensusState()`, `NewMsgHeader()`, `Hash()`, crypto helpers
- **`p/aib/ibc/testing`** - `NewExistenceProof()` for ICS-23 proofs
- **`r/aib/ibc/apps/testing`** - Mock `IBCApp` that records all callback invocations; use `SetOnSendPacketReturn()` etc. to configure, `Report()` to verify
- **`r/aib/ibc/apps/transfer`** - `GRC20BalanceOf(ibcDenom, addr)` to query voucher token balances; filetests mint vouchers via a real `RecvPacket` flow

### Assertion Libraries

```gno
import (
    "gno.land/p/nt/urequire"  // fails test immediately
    "gno.land/p/nt/uassert"   // records failure, continues
)

urequire.NoError(t, err)
urequire.ErrorContains(t, err, "expected substring")
uassert.Equal(t, expected, actual)
```

## E2E Tests

Cross-chain e2e tests live in `e2e/`. They validate the full IBC v2 lifecycle between a real AtomOne chain (`10-gno` light client) and a real Gno chain (`07-tendermint` light client), with the ts-relayer relaying packets. Tests are written in Go using testify suites — no Cosmos SDK dependency, interaction via `docker exec` + HTTP only.

### Components

| Component | Source | Branch | Binary |
|-----------|--------|--------|--------|
| AtomOne | `atomone-hub/atomone` | `main` | `atomoned` |
| Gno | `gnolang/gno` | `master` | `gnodev` + `gnokey` |
| Relayer | `ghcr.io/allinbits/ibc-v2-ts-relayer:latest` | (pre-built image) | `ibc-v2-ts-relayer` |
| tx-indexer | `ghcr.io/gnolang/tx-indexer:latest` | (pre-built image) | — |

### Running

```bash
cd e2e
make test       # Full flow: build images → start services → run Go tests → teardown
make test-only  # Run Go tests against already-running infrastructure
make up         # Start all services (gno, atomone, tx-indexer, relayer)
make logs       # Follow all service logs
make down       # Stop + remove volumes
make clean      # Stop + remove volumes + remove images
```

### Directory Layout

```
e2e/
├── docker-compose.yml      # 4 services: gno, atomone, tx-indexer, relayer
├── Makefile                # COMPOSE_PROJECT_NAME=e2e, --force-recreate
├── .env                    # TEST_MNEMONIC, chain IDs, receiver address
├── go.mod / go.sum         # Only deps: testify, godotenv
├── gno/
│   ├── Dockerfile          # git clone gnolang/gno@master, builds gnodev+gnokey
│   └── entrypoint.sh       # gnodev local with resolvers for aibgno + examples
├── atomone/
│   ├── Dockerfile          # git clone atomone-hub/atomone@main
│   └── entrypoint.sh       # Single-validator init, fast blocks, starts atomoned
├── relayer/
│   └── entrypoint.sh       # Configures mnemonics, gas prices, relay path
├── config.go               # Config struct, loads .env + env overrides
├── docker.go               # getContainerID, dockerExec, dockerExecStdin
├── query.go                # Gno queries (gnokey via docker exec), AtomOne queries (REST)
├── tx.go                   # buildMsgSendPacket, buildUnsignedTx
├── tx_test.go              # signAndBroadcastAtomOneTx, signAndBroadcastGnoCall (suite methods)
├── suite_test.go           # Testify suite: SetupSuite, waitForIBCClients, gnokey helpers
└── ibc_transfer_test.go    # TestIBCTransferAtomOneToGno, TestIBCTransferGnoToAtomOne
```

### Ports

| Service | Host Port → Container | Description |
|---------|----------------------|-------------|
| gno | 26657 → 26657 | Tendermint RPC |
| gno | 8888 → 8888 | gnoweb |
| tx-indexer | 48546 → 8546 | GraphQL (for relayer) |
| atomone | 36657 → 26657 | Tendermint RPC |
| atomone | 1317 → 1317 | REST API |
| atomone | 9090 → 9090 | gRPC |

### Test Flow

1. **SetupSuite**: Load config, verify health, get container IDs, get sender address, recover gnokey test key, wait for IBC clients + counterparty registration
2. **AtomOne→Gno**: Build unsigned MsgSendPacket JSON, sign+broadcast via `atomoned`, verify sender balance decreased, poll GRC20 balance on Gno
3. **Gno→AtomOne**: Call `transfer.Transfer` via `gnokey maketx call`, verify sender ugnot decreased, poll IBC voucher balance on AtomOne

### Key Technical Details

- **Gno queries use `docker exec gnokey query vm/qrender`** — gnoweb wraps output in HTML so can't parse JSON from it
- **AtomOne queries use REST API** — standard Cosmos SDK endpoints work; IBC v2 channel endpoints (`/ibc/core/channel/v2/...`) return "Not Implemented"
- **timeout_timestamp uses seconds** (not nanoseconds) — `time.Now().Add(time.Hour).Unix()`
- **Fees must be in uphoton** — AtomOne requires photon for tx fees, not uatone
- **MsgSendPacket** built as raw JSON with base64-encoded protobuf payload (no Cosmos SDK dependency)
- **IBC denom hash**: `SHA256("transfer/<clientID>/<baseDenom>")` uppercase hex
- **Relayer image**: `ghcr.io/allinbits/ibc-v2-ts-relayer:latest` — pre-built, configured via mounted `entrypoint.sh`
- **Relayer uses `--dquery`** for Gno's GraphQL endpoint: `http://tx-indexer:8546/graphql/query`
- **Sign+broadcast retries on sequence mismatch** — the relayer shares the same account (TEST_MNEMONIC), causing occasional races
- **`--force-recreate` required** in `docker compose up` to avoid stale container state (e.g. validator key already exists)
- **Adena dev build required for txlinks** — the transfer realm's render page exposes `txlink`-generated transaction links that open Adena. The published Adena release only accepts requests from `gno.land` / `*.gnoland.network`; sending from `localhost:8888` **silently fails** (no error popup — the click just does nothing). Use a locally built Adena in **dev mode** (`yarn build:dev` — i.e. `webpack --mode=development` — in `adena-wallet/packages/adena-extension`, then load the unpacked extension) so the chain-id `dev` and `127.0.0.1` origin are accepted. The e2e entrypoint sets `-web-help-remote http://127.0.0.1:26657` so Adena's downstream RPC fetch resolves correctly.
