# IBC Transfer App

ICS-20 Fungible Token Transfer implementation for IBC v2 on Gno. Enables
cross-chain token transfers between Gno and any IBC v2 compatible chain.

## Transfer

`Transfer` is the single entry point for sending any token to another chain. The
token type is detected automatically from the `denom` argument:

| Token type | Denom format | Example | Mechanism |
|---|---|---|---|
| Native coin | plain string | `ugnot` | Escrowed via `SentCoins` |
| IBC voucher | `ibc/{hash}` | `ibc/CAEF9C...` | Burned from sender |
| GRC20 token | grc20reg key | `gno.land/r/demo/foo.FOO` | Escrowed via `TransferFrom` |

Signature:

```gno
func Transfer(
    cur realm,
    clientID string,           // IBC client on this chain (e.g. "07-tendermint-1")
    receiver string,           // recipient address on destination chain
    denom string,              // token denomination (see table above)
    amount int64,              // amount to transfer
    timeoutTimestamp uint64,   // unix seconds after which the packet times out
    memo string,               // arbitrary memo included in the IBC packet
) (packet types.MsgSendPacket, sequence uint64)
```

### Native coin

The coin must be attached to the transaction via the `-send` flag and must match
`denom` and `amount`.

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
    -send 100ugnot \
    -args "07-tendermint-1" -args "atone1abc..." -args "ugnot" -args "100" \
    -args "1719878400" -args "" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

### IBC voucher

IBC vouchers are GRC20 tokens minted when receiving tokens from another chain.
They are burned on transfer back to the source chain.

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
    -args "07-tendermint-1" -args "atone1abc..." \
    -args "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8" \
    -args "100" -args "1719878400" -args "memo" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

For local voucher interactions on Gno, the transfer realm also exposes
`MsgCall`-friendly helper functions:

```gno
func TransferVoucher(cur realm, ibcDenom string, to address, amount int64)
func ApproveVoucher(cur realm, ibcDenom string, spender address, amount int64)
```

Use `TransferVoucher` to move voucher tokens between Gno addresses without
going through an IBC send:

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func TransferVoucher \
    -args "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8" \
    -args "g1recipient..." -args "100" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

Use `ApproveVoucher` to set a spender allowance for a voucher token:

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func ApproveVoucher \
    -args "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8" \
    -args "g1spender..." -args "100" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

### GRC20 token

The caller must first approve the transfer app realm to spend the tokens.

From Gno code (e.g. in a `MsgRun` script):

```gno
transferAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
mytoken.Approve(cross, caller, transferAddr, amount)
```

Or via `gnokey` directly, where `g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00` is
the transfer app realm address:

```
gnokey maketx call -pkgpath gno.land/r/demo/foo -func Approve \
    -args "g1caller..." -args "g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00" -args "100" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

Then call Transfer with the grc20reg key as denom:

```
gnokey maketx call -pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
    -args "07-tendermint-1" -args "atone1abc..." \
    -args "gno.land/r/demo/foo.FOO" -args "100" \
    -args "1719878400" -args "" \
    -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid gnoland-1 ADDRESS
```

> [!IMPORTANT]
> GRC20 denoms are encoded into slash-free aliases for IBC packets by replacing
> `/` with `:` (e.g. `gno.land/r/demo/foo.FOO` becomes
> `gno.land:r:demo:foo.FOO`). The counterparty chain sees the aliased form, not
> the original grc20reg key.

## Query endpoints

All endpoints return JSON and are accessible via gnoweb or `gnokey query vm/qrender`.

| Path | Description |
|---|---|
| `denoms` | List all registered IBC denominations |
| `denoms/ibc/{hash}` | Details for a specific IBC denom (base, path, denom) |
| `total_escrow/{denom}` | Total escrowed amount for a native denom |
| `vouchers` | List all voucher tokens (paginated, includes `grc20reg_key`) |
| `voucher/ibc/{hash}` | Voucher token metadata (denom, grc20reg_key, name, symbol, decimals, total supply) |
| `voucher/ibc/{hash}/balance/{addr}` | Voucher balance for an address |

Example:

```
gnokey query vm/qrender -data "gno.land/r/aib/ibc/apps/transfer:total_escrow/ugnot"
```

```json
{"denom":"ugnot","amount":100}
```

## Helper functions

### VoucherBalanceOf

Query the balance of a voucher token for a given address. Returns 0 if the
voucher does not exist.

```gno
balance := transfer.VoucherBalanceOf("ibc/CAEF9C...", addr)
```

### GRC20Alias

Convert a grc20reg key to the slash-free alias used in IBC packets.

```gno
alias := transfer.GRC20Alias("gno.land/r/demo/foo.FOO")
// "gno.land:r:demo:foo.FOO"
```

### NewDenom / NewHop

Construct a `Denom` to compute the expected IBC denom hash:

```gno
denom := transfer.NewDenom("uphoton", transfer.NewHop(transfer.PortID, "07-tendermint-1"))
ibcDenom := denom.IBCDenom()
// "ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8"
```

## DEX integration for voucher tokens

Voucher tokens minted on `RecvPacket` are standard GRC20 tokens registered in
`grc20reg`. A DEX (e.g. Gnoswap) can discover and list them like any other
GRC20 token.

### Discovery

Voucher tokens can be discovered in two ways:

1. **From the transfer app** — query the `vouchers` render endpoint to list all
   voucher tokens with their metadata. Each entry includes a `grc20reg_key`
   field with the token's grc20reg key, ready for direct lookup. Supports
   pagination.

2. **From `grc20reg`** — voucher tokens are registered with the key
   `gno.land/r/aib/ibc/apps/transfer.{HASH}`, where `{HASH}` is the uppercase
   hex SHA256 hash from the `ibc/{HASH}` denom. Enumerate entries with the
   `gno.land/r/aib/ibc/apps/transfer.` prefix.

The token name is the base denomination (e.g. `uatom`) and the symbol is the
full IBC denom (e.g. `ibc/CAEF9C...`). For richer metadata (trace hops, total
supply), query the render endpoint `voucher/ibc/{HASH}`.

### Trading

1. A user receives voucher tokens via an IBC `RecvPacket`.
2. The user approves the DEX realm address to spend their voucher tokens
   (`Approve`).
3. The DEX interacts with the voucher via the standard GRC20 teller interface
   (`TransferFrom`, `BalanceOf`, etc.).

### Multiple vouchers for the same base denom

The same base denomination (e.g. `uatom`) arriving from different chains
produces distinct voucher tokens with different IBC hashes. A DEX should use the
full `ibc/{HASH}` denom (available as the token symbol) to distinguish them, and
query `denoms/ibc/{HASH}` to resolve the trace path for display purposes.

## Events

### `ibc_transfer`

Emitted in `OnSendPacket` for every outgoing transfer packet.

| Attribute | Description |
|---|---|
| `sender` | Sender address on source chain |
| `receiver` | Receiver address on destination chain |
| `denom` | Full denom path |
| `amount` | Transfer amount |
| `memo` | Memo text |

### `fungible_token_packet`

Emitted on `OnRecvPacket`:

| Attribute | Description |
|---|---|
| `sender` | Sender address |
| `receiver` | Receiver address |
| `denom` | Full denom path |
| `amount` | Amount |
| `memo` | Memo text |
| `success` | `"true"` or `"false"` |
| `error` | Error message (on failure) |

Also emitted on `OnAcknowledgementPacket`:

| Attribute | Description |
|---|---|
| `sender` | Sender address |
| `receiver` | Receiver address |
| `denom` | Full denom path |
| `amount` | Amount |
| `memo` | Memo text |
| `acknowledgement` | Acknowledgement bytes |

### `denomination`

Emitted when a new voucher denom is created during `OnRecvPacket`.

| Attribute | Description |
|---|---|
| `denom_hash` | Uppercase hex SHA256 hash |
| `denom` | JSON representation of the Denom |

### `timeout`

Emitted on `OnTimeoutPacket`. Tokens are refunded to the original sender.

| Attribute | Description |
|---|---|
| `receiver` | Refund recipient (original sender) |
| `denom` | Full denom path |
| `amount` | Refunded amount |
| `memo` | Original memo |

## IBC packet lifecycle

1. **Transfer** -- Caller invokes `Transfer`. Tokens are escrowed (native/GRC20)
   or burned (voucher). An IBC packet is sent via `core.SendPacket`.

2. **RecvPacket** -- The destination chain receives the packet. If the token
   originated on the destination chain, the escrowed tokens are returned.
   Otherwise a voucher GRC20 token is minted and registered in `grc20reg`.

3. **Acknowledgement** -- On success, only a `fungible_token_packet` event is
   emitted. On failure, the sender is refunded (re-mint vouchers, unescrow
   native/GRC20).

4. **Timeout** -- If the packet is not received before `timeoutTimestamp`, the
   sender is refunded using the same mechanism as a failed acknowledgement.
