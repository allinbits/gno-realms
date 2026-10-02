#!/usr/bin/env bash
#
# Build ONE unsigned transaction holding a MsgAddPackage for every entry of
# packages.sh, in deploy order, so the whole deploy needs a single signing
# round (for instance by the AIB multisig). Nothing is signed or sent here.
#
# Usage:
#   CREATOR=g1... ./scripts/make-deploy-tx.sh                 # writes ./deploy-tx.json
#   CREATOR=aib-msig OUT=/tmp/tx.json ./scripts/make-deploy-tx.sh
#   KEEP_TESTS=1 CREATOR=g1... ./scripts/make-deploy-tx.sh    # keep filetests/ and *_test.gno
#
# CREATOR is the account that submits and pays, as a bech32 address or the name
# of a key in the local keybase (the multisig key, typically). It does not need
# to be unlocked: gnokey only reads the address to compose the messages.
#
# Tests are stripped by default (filetests/ directories, *_test.gno,
# *_filetest.gno): with them the sources weigh about 1.4 MB, above the chain's
# MaxTxBytes (1 MB on onyx), and on-chain they only cost storage deposit.
#
# Signing follows the gnokey multisig flow (gno repo,
# docs/users/interact-with-gnokey.md, "Using a k-of-n multisig"): each signer
# signs the same document with the multisig account's number and sequence,
# the multisig holder combines the signatures, anyone broadcasts. The script
# prints those commands with the actual values at the end.
#
# Chain policy notes:
# - "inert" (onyx, mainnet): every message parks; approvers enable the packages
#   one by one in deploy order, and the storage deposit is taken from CREATOR at
#   enablement, so CREATOR must then hold MAX_DEPOSIT per package plus the fee.
# - "permissionless" (gnodev): messages execute in order within the transaction,
#   each type-checked against the ones before it. Gas is charged for all of
#   them, so GAS_WANTED must cover the whole tx and stay under the block's
#   MaxGas (3,000,000,000 on onyx).

set -euo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/packages.sh"

CREATOR="${CREATOR:?set CREATOR to the submitting address or key name (e.g. the multisig)}"
GAS_FEE="${GAS_FEE:-15000000ugnot}"
GAS_WANTED="${GAS_WANTED:-2500000000}"
MAX_DEPOSIT="${MAX_DEPOSIT:-100000000ugnot}" # per package
MEMO="${MEMO:-}"
OUT="${OUT:-deploy-tx.json}"
KEEP_TESTS="${KEEP_TESTS:-0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Composing one tx with ${#PACKAGES[@]} MsgAddPackage for $CHAIN_ID ($REMOTE)"
echo "    creator=$CREATOR  gas-fee=$GAS_FEE  gas-wanted=$GAS_WANTED  max-deposit=$MAX_DEPOSIT/pkg  keep-tests=$KEEP_TESTS"
echo

# ---- compose one message per package ---------------------------------------
# gnokey reads the package directory (including filetests/) and emits the
# unsigned tx document on stdout when -broadcast=false. One tx per package
# here; their messages are merged below.
i=0
for entry in "${PACKAGES[@]}"; do
  i=$((i + 1))
  pkgpath="${entry%%:*}"
  pkgdir="${entry##*:}"
  if [[ ! -d "$pkgdir" ]]; then
    echo "ERROR: directory not found: $pkgdir" >&2
    exit 1
  fi

  stage="$WORK/stage/$i"
  mkdir -p "$stage"
  if [[ "$KEEP_TESTS" == "1" ]]; then
    cp -R "$pkgdir"/. "$stage"/
  else
    # Top-level files only (drops filetests/ and any nested package dir), minus
    # unit tests and filetests.
    find "$pkgdir" -maxdepth 1 -type f ! -name '*_test.gno' ! -name '*_filetest.gno' \
      -exec cp {} "$stage"/ \;
  fi

  printf "  [%2d/%2d] %-56s %7d bytes\n" "$i" "${#PACKAGES[@]}" "$pkgpath" "$(cat "$stage"/* | wc -c)"
  "${GNOKEY_CMD[@]}" maketx addpkg \
    -pkgpath "$pkgpath" \
    -pkgdir "$stage" \
    -gas-fee "$GAS_FEE" \
    -gas-wanted "$GAS_WANTED" \
    -max-deposit "$MAX_DEPOSIT" \
    -broadcast=false \
    "$CREATOR" > "$WORK/msg-$i.json"
done
echo

# ---- merge ------------------------------------------------------------------
python3 - "$WORK" "${#PACKAGES[@]}" "$OUT" "$MEMO" <<'PY'
import json, sys
work, n, out, memo = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
msgs, fee = [], None
for i in range(1, n + 1):
    with open(f"{work}/msg-{i}.json") as f:
        tx = json.load(f)
    msgs.extend(tx["msg"])
    fee = fee or tx["fee"]
tx = {"msg": msgs, "fee": fee, "signatures": None, "memo": memo}
with open(out, "w") as f:
    json.dump(tx, f, separators=(",", ":"))
print(f"==> {out}: {len(msgs)} messages, {len(json.dumps(tx, separators=(',', ':')).encode())} bytes (JSON)")
PY

# ---- limits -----------------------------------------------------------------
# MaxTxBytes applies to the amino-binary tx, which is smaller than the JSON
# document, so comparing the JSON size is conservative.
if max_tx_bytes="$(curl -sf --max-time 10 "$REMOTE/consensus_params" 2>/dev/null \
    | grep -o '"MaxTxBytes": *"[0-9]*"' | sed 's/[^0-9]//g')" && [[ -n "$max_tx_bytes" ]]; then
  size="$(wc -c < "$OUT")"
  if (( size > max_tx_bytes )); then
    echo "ERROR: tx is $size bytes, above the chain's MaxTxBytes ($max_tx_bytes); split the deploy or strip more" >&2
    exit 1
  fi
  echo "    fits MaxTxBytes=$max_tx_bytes"
fi

# ---- next steps -------------------------------------------------------------
creator_addr="$CREATOR"
if [[ ! "$CREATOR" =~ ^g1[a-z0-9]{38}$ ]]; then
  creator_addr="$("${GNOKEY_CMD[@]}" list 2>/dev/null | sed -n "s/^[0-9]*\. $CREATOR .*addr: \(g1[a-z0-9]*\).*/\1/p" | head -1)"
fi
acct="$("${GNOKEY_CMD[@]}" query "auth/accounts/$creator_addr" -remote "$REMOTE" 2>/dev/null || true)"
acct_num="$(grep -o '"account_number": *"[0-9]*"' <<<"$acct" | sed 's/[^0-9]//g' || true)"
acct_seq="$(grep -o '"sequence": *"[0-9]*"' <<<"$acct" | sed 's/[^0-9]//g' || true)"

cat <<EOT

==> Next steps (multisig flow; account number/sequence are those of the creator $creator_addr right now:
    account-number=${acct_num:-?} account-sequence=${acct_seq:-?}; re-check before signing if another tx was sent meanwhile)

  1. Each signer, on their own machine, with the shared $OUT:
       gnokey sign -tx-path $OUT -chainid $CHAIN_ID -account-number ${acct_num:-N} -account-sequence ${acct_seq:-S} \\
           -output-document <name>-sig.json <signer-key>
  2. Whoever holds the multisig key combines the signatures (member order matters, see the gno docs):
       gnokey multisign -tx-path $OUT -signature <a>-sig.json -signature <b>-sig.json <multisig-key>
  3. Broadcast:
       gnokey broadcast -remote $REMOTE $OUT
  4. On an "inert" chain the packages park until the approvers enable them; poll with
       gnokey query vm/qpkgmeta_json -data <pkgpath> -remote $REMOTE   (status: inert -> live)
EOT
