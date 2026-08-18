#!/usr/bin/env bash
# Send tokens via IBC v2 MsgSendPacket from the AtomOne to gno, using a local
# `atomoned` binary signing against a public RPC.
#
# Prerequisites:
#   - atomoned installed locally and on $PATH
#   - your signing key imported in the local keyring (default: test backend).
#     KEY's address MUST equal $SENDER, otherwise signing fails with a mismatch.
#
# Defaults: 1 ATONE (1_000_000 uatone) atone1z437…→g1z437… via 10-gno-15
# Override via env: NODE, CHAIN_ID, CLIENT_ID, KEY, KEYRING_BACKEND, SENDER,
#   RECEIVER, DENOM, AMOUNT, FEE_DENOM, FEE_AMOUNT, GAS, MEMO, TIMEOUT, ATOMONE_HOME.
#
# Usage:
#   ./scripts/transfer-atomone-to-gno.sh
#   AMOUNT=5000000 ./scripts/transfer-atomone-to-gno.sh
#
# Returning a voucher to gno: DENOM must be the expanded trace
# ----------------------------------------------------------------------------
# To send back a voucher that originated on gno (e.g. ugnot received here as
# ibc/<HASH>), DENOM must be the *trace* the voucher was minted from, not the
# local ibc/<HASH> spelling:
#
#   DENOM='transfer/10-gno-15/ugnot' AMOUNT=1000000 ./scripts/transfer-atomone-to-gno.sh
#
# The trace is "transfer/<source client on this chain>/<base denom>", and
# hashing it reproduces the voucher you hold:
# SHA256("transfer/10-gno-15/ugnot") == B4C7F88F0BDA20D0C0549EEBB9436DEF5FBD2882B861F6D1BB033F592D19836E
#
# Passing ibc/<HASH> instead fails at execution (tx code 3, funds untouched):
#
#   base denomination ibc/B4C7F88F... cannot contain slashes for IBC v2 packet:
#   invalid denomination for cross-chain transfer
#
# ibc/<HASH> is chain-local and meaningless to the counterparty, so an ICS-20
# payload has to carry the expanded trace. A MsgTransfer would have the transfer
# module resolve the hash before building the packet; this script hand-builds the
# payload inside a raw MsgSendPacket, which skips that resolution -- so the
# canonical form is ours to supply, and ibc-go's "no slashes in the base
# denomination" check is what rejects the unresolved one.
#
# The gno side does not have this constraint: r/aib/ibc/apps/transfer.Transfer
# resolves ibc/<HASH> to the trace itself, so the ibc/<HASH> form is correct
# there (see that realm's README, "IBC voucher").

set -euo pipefail

NODE="${NODE:-https://atomone-testnet-1-rpc.allinbits.services:443}"
CHAIN_ID="${CHAIN_ID:-atomone-testnet-1}"
CLIENT_ID="${CLIENT_ID:-10-gno-15}" # tracks sapphire-1; counterparty 07-tendermint-1
KEY="${KEY:-relayer}"
KEYRING_BACKEND="${KEYRING_BACKEND:-test}"
KEYRING_DIR="${KEYRING_DIR:-~/.atomone-testnet}"
SENDER="${SENDER:-atone1z437dpuh5s4p64vtq09dulg6jzxpr2hdgu88r6}" # relayer
RECEIVER="${RECEIVER:-g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x}" # relayer
DENOM="${DENOM:-uatone}"
AMOUNT="${AMOUNT:-1000000}"
FEE_DENOM="${FEE_DENOM:-uphoton}"
FEE_AMOUNT="${FEE_AMOUNT:-10000}"
GAS="${GAS:-300000}"
MEMO="${MEMO:-}"
TIMEOUT="${TIMEOUT:-$(( $(date +%s) + 3600 ))}"
ATOMONE_HOME="${ATOMONE_HOME:-}"

HOME_FLAG=()
[[ -n "$ATOMONE_HOME" ]] && HOME_FLAG=(--home "$ATOMONE_HOME")

# Encode FungibleTokenPacketData proto: denom(1), amount(2), sender(3), receiver(4), memo(5)
PAYLOAD_B64=$(python3 - "$DENOM" "$AMOUNT" "$SENDER" "$RECEIVER" "$MEMO" <<'PY'
import base64, sys
def f(tag, s):
    b = s.encode()
    out = bytes([tag<<3 | 2])
    n = len(b)
    while n > 0x7f:
        out += bytes([n & 0x7f | 0x80]); n >>= 7
    out += bytes([n]) + b
    return out
denom, amount, sender, receiver, memo = sys.argv[1:6]
buf = f(1, denom) + f(2, amount) + f(3, sender) + f(4, receiver)
if memo:
    buf += f(5, memo)
print(base64.b64encode(buf).decode())
PY
)

UNSIGNED=$(cat <<JSON
{
  "body": {
    "messages": [{
      "@type": "/ibc.core.channel.v2.MsgSendPacket",
      "source_client": "$CLIENT_ID",
      "timeout_timestamp": "$TIMEOUT",
      "payloads": [{
        "source_port": "transfer",
        "destination_port": "transfer",
        "version": "ics20-1",
        "encoding": "application/x-protobuf",
        "value": "$PAYLOAD_B64"
      }],
      "signer": "$SENDER"
    }],
    "memo": "",
    "timeout_height": "0"
  },
  "auth_info": {
    "fee": {
      "amount": [{"denom": "$FEE_DENOM", "amount": "$FEE_AMOUNT"}],
      "gas_limit": "$GAS"
    },
    "signer_infos": []
  },
  "signatures": []
}
JSON
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Transferring $AMOUNT $DENOM from $SENDER -> $RECEIVER"
echo "    via $CLIENT_ID on $CHAIN_ID ($NODE), timeout=$TIMEOUT"
printf '%s\n' "$UNSIGNED" > "$TMP/unsigned.json"

SIGN_CMD=(atomoned tx sign "$TMP/unsigned.json"
    --from "$KEY" --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING_BACKEND"
    --keyring-dir "$KEYRING_DIR"
    "${HOME_FLAG[@]}" --node "$NODE"
    --output-document "$TMP/signed.json")
BROADCAST_CMD=(atomoned tx broadcast "$TMP/signed.json" --node "$NODE" --output json)

echo "==> ${SIGN_CMD[*]}"
"${SIGN_CMD[@]}"

echo "==> ${BROADCAST_CMD[*]}"
"${BROADCAST_CMD[@]}"
