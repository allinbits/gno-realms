# AGENTS.md

IBC v2 implementation for Gno (similar to IBC Eureka for Ethereum). Gno smart contracts ("realms" and "packages") enabling cross-chain communication via the Inter-Blockchain Communication protocol.

## Build & Test Commands

```bash
make test           # Run all tests (gno filetests + Go tests)
make gnodev         # Start local gno node with all realms/packages
make update-fork    # Update the allinbits/gno fork dependency
```

CI runs unit + e2e tests on every push (`.github/workflows/test.yml`).

Under the hood:
- `go tool gno test ./gno.land/...` runs all Gno tests (unit tests + filetests)
- `go test -C ./cmd/gen-block-signatures` and `go test -C ./cmd/gen-proof` run Go tests

**Important:** Always use `go tool gno test`, not a standalone `gno` binary. The gno fork is resolved via `go mod` replace directives, so `go tool gno` picks up the correct fork automatically. A standalone `gno` may point to upstream and miss fork-specific features.

Run a single package's tests:
```bash
go tool gno test ./gno.land/p/aib/ibc/types
```

Run a specific test by name:
```bash
go tool gno test -run TestPacketValidateBasic ./gno.land/p/aib/ibc/types
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
    limitedbanker/            # Banker wrapper with spending limits
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

### The `cur realm` and `cross` Keywords

Realm functions that need caller context use `cur realm` parameter:
```gno
func CreateClient(cur realm, clientState lightclient.ClientState, ...) string
```

Callers pass `cross` as the argument:
```gno
clientID := core.CreateClient(cross, clientState, consensusState)
```

### MsgRun vs MsgCall

Most IBC functions require `MsgRun` (not `MsgCall`) because they take complex arguments (structs, slices of bytes). See `gno.land/r/aib/ibc/core/README.md` for examples.

### Gno Standard Library

- `chain/banker` - coin manipulation interface
- `chain.Emit(eventType, kvPairs...)` - event emission
- `runtime.OriginCaller()`, `runtime.PreviousRealm()`, `runtime.CurrentRealm()` - caller context
- `gno.land/p/nt/avl/v0` - AVL tree (primary key-value storage)
- `gno.land/p/nt/seqid/v0` - monotonic ID generation
- `gno.land/p/nt/ufmt/v0` - string formatting
- `gno.land/p/nt/urequire/v0` / `gno.land/p/nt/uassert/v0` - test assertions

## GRC20 Voucher Tokens

IBC voucher tokens (minted on RecvPacket for cross-chain tokens) use **GRC20 tokens** instead of native banker coins. This enables DeFi compatibility (Gnoswap, etc.) via the `grc20reg` registry.

### Key Dependencies
- `gno.land/p/demo/tokens/grc20` - GRC20 token implementation (`NewToken`, `PrivateLedger.Mint/Burn`)
- `gno.land/r/demo/defi/grc20reg` - Global token registry (`Register`, `Get`)

### How It Works
- **OnRecvPacket (mint)**: `getOrCreateGRC20(ibcDenom, baseDenom)` creates a GRC20 token + registers in grc20reg, then `inst.ledger.Mint(receiver, amount)`
- **OnSendPacket (burn)**: `getGRC20(ibcDenom)` retrieves the token, then `inst.ledger.Burn(sender, amount)`
- **Refund (ack error / timeout)**: `getGRC20(ibcDenom)` + `inst.ledger.Mint(sender, amount)` to re-mint

### What Uses Native Banker
- **Escrow/unescrow** of native tokens (ugnot, etc.) still uses `chain/banker`
- Native token escrow in `OnSendPacket` uses `cur.SentCoins()` to verify coins sent with the transaction

### Voucher Render Endpoints
- `voucher/ibc/{hash}` - Token info (name, symbol, total supply)
- `voucher/ibc/{hash}/balance/{address}` - Balance of an address

## Fork Dependency Management

This project depends on a **fork** of gnolang/gno at `github.com/tbruyelle/gno@tbruyelle/origin-send-filter`. The fork is managed via `go mod replace` directives in `go.mod`:

```
github.com/gnolang/gno => github.com/tbruyelle/gno@<commit-hash>
github.com/gnolang/gno/contribs/gnodev => github.com/tbruyelle/gno/contribs/gnodev@<commit-hash>
```

Run `make update-fork` to pull the latest fork changes (resolves the branch to a commit hash automatically).

## Testing Patterns

### Filetests (primary test mechanism)

Files named `z*_filetest.gno` in realm directories. These are integration tests that run as standalone `package main` programs with expected output matching:

```gno
package main

import "gno.land/r/aib/ibc/core"

func main() {
    clientID := core.CreateClient(cross, clientState, consensusState)
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
| AtomOne | `atomone-hub/atomone` | `feat/gno-lc` | `atomoned` |
| Gno | `tbruyelle/gno` | `tbruyelle/origin-send-filter` | `gnodev` + `gnokey` |
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
│   ├── Dockerfile          # git clone tbruyelle/gno, builds gnodev+gnokey
│   └── entrypoint.sh       # gnodev local with resolvers for aibgno + examples
├── atomone/
│   ├── Dockerfile          # git clone atomone-hub/atomone@feat/gno-lc
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
| gno | 46657 → 26657 | Tendermint RPC |
| gno | 48888 → 8888 | gnoweb |
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
