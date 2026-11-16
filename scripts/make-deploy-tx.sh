#!/usr/bin/env bash
#
# Build the unsigned transactions holding a MsgAddPackage for every entry of
# packages.sh, in deploy order, packed into as few transactions as the chain's
# MaxTxBytes allows, so the deploy needs few signing rounds (for instance by
# the AIB multisig). Nothing is signed or sent here.
#
# When everything fits in one transaction it is written to OUT (default
# ./deploy-tx.json). Otherwise the messages are split, still in deploy order,
# into OUT with -1, -2, ... before its extension (./deploy-tx-1.json, ...),
# signed with consecutive account sequences and broadcast in that order.
#
# Usage:
#   ./scripts/make-deploy-tx.sh                               # creator: the AIB multisig, writes ./deploy-tx.json (or -1, -2, ...)
#   OUT=/tmp/tx.json ./scripts/make-deploy-tx.sh
#   CREATOR=g1... ./scripts/make-deploy-tx.sh                 # another creator (address or local key name)
#   KEEP_TESTS=1 ./scripts/make-deploy-tx.sh                  # keep filetests/ and *_test.gno
#   ONLY=gno.land/r/aib/ibc/core/impl/v0 ./scripts/make-deploy-tx.sh   # a subset of packages.sh (comma-separated), e.g. one implementation
#   RELAYERS=g1...,g1... ./scripts/make-deploy-tx.sh          # also write the ibcgov MsgRun adding these relayers
#
# RELAYERS (comma-separated addresses) also writes RELAYERS_OUT (default
# ./add-relayers.gno): the MsgRun script by which the ibcgov governor records
# one add-relayer decision per address (core.AddRelayer accepts ibcgov only;
# see gno.land/r/aib/ibc/core/README.md, "Relayer whitelist").
#
# CREATOR is the account that submits and pays, by default MULTISIG_ADDR from
# env.sh. It also becomes the ibcgov governor: ibcgov's init records its
# deployer (on an inert chain, the creator stamped at submission), the one
# account that decides by Govern until it yields to GovDAO. It does not need to be in the local keybase or unlocked: gnokey only
# reads the address to compose the messages. It must own the `aib` namespace on
# the target chain (r/sys/names), or every message is rejected.
#
# Tests are stripped by default (filetests/ directories, *_test.gno,
# *_filetest.gno): the chain never runs them and type-checks production files
# only, so on-chain they only cost storage deposit and transaction bytes.
#
# Splitting: MaxTxBytes is read from the chain (MAX_TX_BYTES overrides it, and
# is required when the query fails). Each transaction's JSON document, larger
# than the amino-binary tx the limit applies to, stays SIG_RESERVE bytes under
# it: room for the signatures added later (a multisig adds its members' public
# keys and one signature per signer). A package too large on its own is an
# error. GAS_WANTED and GAS_FEE apply to each transaction.
#
# Signing follows the gnokey multisig flow (gno repo,
# docs/users/interact-with-gnokey.md, "Using a k-of-n multisig"): each signer
# signs the same documents with the multisig account's number and sequences,
# the multisig holder combines the signatures, anyone broadcasts. The script
# prints those commands with the actual values at the end.
#
# Chain policy notes:
# - "inert" (onyx, mainnet): every message parks; approvers enable the packages
#   one by one in deploy order, and the storage deposit is taken from CREATOR at
#   enablement, so CREATOR must then hold MAX_DEPOSIT per package plus the fee.
# - "permissionless" (gnodev): messages execute in order within the transaction,
#   each type-checked against the ones before it. Gas is charged for all of
#   them, so GAS_WANTED must cover each whole tx and stay under the block's
#   MaxGas (3,000,000,000 on onyx). A transaction only sees the packages of
#   the ones before it once they are committed: broadcast them in order.

set -euo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/packages.sh"

CREATOR="${CREATOR:-$MULTISIG_ADDR}"
GAS_FEE="${GAS_FEE:-15000000ugnot}"
GAS_WANTED="${GAS_WANTED:-2500000000}"
MAX_DEPOSIT="${MAX_DEPOSIT:-100000000ugnot}" # per package
MEMO="${MEMO:-}"
OUT="${OUT:-deploy-tx.json}"
KEEP_TESTS="${KEEP_TESTS:-0}"
RELAYERS="${RELAYERS:-}"
RELAYERS_OUT="${RELAYERS_OUT:-add-relayers.gno}"
MAX_TX_BYTES="${MAX_TX_BYTES:-}"
SIG_RESERVE="${SIG_RESERVE:-20000}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

relayers=()
if [[ -n "$RELAYERS" ]]; then
  IFS=',' read -r -a relayers <<< "$RELAYERS"
  for r in "${relayers[@]}"; do
    if [[ ! "$r" =~ ^g1[a-z0-9]{38}$ ]]; then
      echo "ERROR: RELAYERS: not a g1 address: '$r'" >&2
      exit 1
    fi
  done
fi

# ---- optional subset --------------------------------------------------------
# ONLY keeps the listed package paths, in packages.sh order; an upgrade deploys
# a single implementation this way. Every listed path must be in packages.sh.
ONLY="${ONLY:-}"
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a wanted <<< "$ONLY"
  filtered=()
  for entry in "${PACKAGES[@]}"; do
    for w in "${wanted[@]}"; do
      [[ "${entry%%:*}" == "$w" ]] && filtered+=("$entry")
    done
  done
  if [[ "${#filtered[@]}" -ne "${#wanted[@]}" ]]; then
    echo "ERROR: ONLY lists ${#wanted[@]} package(s) but ${#filtered[@]} matched packages.sh: $ONLY" >&2
    exit 1
  fi
  PACKAGES=("${filtered[@]}")
fi

# ---- size limit -------------------------------------------------------------
if [[ -z "$MAX_TX_BYTES" ]]; then
  MAX_TX_BYTES="$(curl -sf --max-time 10 "$REMOTE/consensus_params" 2>/dev/null \
    | grep -o '"MaxTxBytes": *"[0-9]*"' | sed 's/[^0-9]//g' || true)"
  if [[ -z "$MAX_TX_BYTES" ]]; then
    echo "ERROR: cannot read MaxTxBytes from $REMOTE; set MAX_TX_BYTES" >&2
    exit 1
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Composing ${#PACKAGES[@]} MsgAddPackage for $CHAIN_ID ($REMOTE)"
echo "    creator=$CREATOR  gas-fee=$GAS_FEE/tx  gas-wanted=$GAS_WANTED/tx  max-deposit=$MAX_DEPOSIT/pkg  keep-tests=$KEEP_TESTS"
echo "    max-tx-bytes=$MAX_TX_BYTES  sig-reserve=$SIG_RESERVE"
echo

# ---- compose one message per package ---------------------------------------
# gnokey reads the staged package directory (all of it) and emits the
# unsigned tx document on stdout when -broadcast=false. One tx per package
# here; their messages are packed into transactions below.
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

# ---- pack -------------------------------------------------------------------
# Greedy, in deploy order: a message joins the current transaction while its
# JSON document stays within MAX_TX_BYTES - SIG_RESERVE, else it opens the next
# one. MaxTxBytes applies to the amino-binary tx, smaller than the JSON, so the
# comparison is conservative. The written files are listed in $WORK/txs.
python3 - "$WORK" "${#PACKAGES[@]}" "$OUT" "$MEMO" "$MAX_TX_BYTES" "$SIG_RESERVE" <<'PY'
import json, os, sys
work, n, out, memo = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
budget = int(sys.argv[5]) - int(sys.argv[6])

def doc(msgs, fee):
    return {"msg": msgs, "fee": fee, "signatures": None, "memo": memo}

def size(tx):
    return len(json.dumps(tx, separators=(",", ":")).encode())

msgs, fee = [], None
for i in range(1, n + 1):
    with open(f"{work}/msg-{i}.json") as f:
        tx = json.load(f)
    msgs.extend(tx["msg"])
    fee = fee or tx["fee"]

groups, cur = [], []
for m in msgs:
    alone = size(doc([m], fee))
    if alone > budget:
        sys.exit(f"ERROR: {m['package']['path']} alone is {alone} bytes (JSON), above "
                 f"MaxTxBytes - SIG_RESERVE ({budget}); strip it or split the package")
    if cur and size(doc(cur + [m], fee)) > budget:
        groups.append(cur)
        cur = []
    cur.append(m)
groups.append(cur)

if len(groups) == 1:
    paths = [out]
else:
    base, ext = os.path.splitext(out)
    paths = [f"{base}-{k}{ext}" for k in range(1, len(groups) + 1)]
with open(f"{work}/txs", "w") as listing:
    for path, group in zip(paths, groups):
        tx = doc(group, fee)
        with open(path, "w") as f:
            json.dump(tx, f, separators=(",", ":"))
        print(f"==> {path}: {len(group)} messages, {size(tx)} bytes (JSON), "
              f"{group[0]['package']['path']} .. {group[-1]['package']['path']}")
        listing.write(path + "\n")
PY
mapfile -t TX_FILES < "$WORK/txs"
echo "    ${#TX_FILES[@]} transaction(s), each at most MaxTxBytes=$MAX_TX_BYTES less a $SIG_RESERVE-byte signature reserve"

# ---- relayer whitelist ------------------------------------------------------
# core.AddRelayer is a governed operation: the core accepts it from ibcgov only,
# so the relayers are added by ibcgov decisions, recorded here by the governor
# (Govern) before its yield. After the yield the same requests go through GovDAO
# proposals instead (see the core README).
if [[ "${#relayers[@]}" -gt 0 ]]; then
  {
    printf 'package main\n\nimport "gno.land/r/aib/ibc/ibcgov"\n\nfunc main(cur realm) {\n'
    for r in "${relayers[@]}"; do
      printf '\tibcgov.Govern(cross(cur), ibcgov.NewCoreAddRelayerRequest(cross(cur), "%s"))\n' "$r"
    done
    printf '}\n'
  } > "$RELAYERS_OUT"
  echo "==> $RELAYERS_OUT: ${#relayers[@]} add-relayer decision(s) for the ibcgov governor"
fi

# ---- next steps -------------------------------------------------------------
creator_addr="$CREATOR"
if [[ ! "$CREATOR" =~ ^g1[a-z0-9]{38}$ ]]; then
  creator_addr="$("${GNOKEY_CMD[@]}" list 2>/dev/null | sed -n "s/^[0-9]*\. $CREATOR .*addr: \(g1[a-z0-9]*\).*/\1/p" | head -1)"
fi
acct="$("${GNOKEY_CMD[@]}" query "auth/accounts/$creator_addr" -remote "$REMOTE" 2>/dev/null || true)"
acct_num="$(grep -o '"account_number": *"[0-9]*"' <<<"$acct" | sed 's/[^0-9]//g' || true)"
acct_seq="$(grep -o '"sequence": *"[0-9]*"' <<<"$acct" | sed 's/[^0-9]//g' || true)"

if [[ "${#relayers[@]}" -gt 0 ]]; then
  RELAYERS_FILE="$RELAYERS_OUT"
  RELAYERS_HINT=" (written to $RELAYERS_OUT)"
else
  RELAYERS_FILE="add-relayers.gno"
  RELAYERS_HINT=" (rerun with RELAYERS=g1...,g1... to write it), one Govern per relayer:
       ibcgov.Govern(cross(cur), ibcgov.NewCoreAddRelayerRequest(cross(cur), \"<relayer-address>\"))"
fi

# Steps 1-3 per transaction: the k-th one (0-based) is signed with the creator's
# sequence + k, since each broadcast consumes one sequence.
sign_cmds="" multisign_cmds="" broadcast_cmds=""
for k in "${!TX_FILES[@]}"; do
  f="${TX_FILES[$k]}"
  seq="S+$k"
  [[ -n "$acct_seq" ]] && seq=$((acct_seq + k))
  [[ "$k" == 0 && -z "$acct_seq" ]] && seq="S"
  sig="<name>-sig-$((k + 1)).json"
  [[ "${#TX_FILES[@]}" == 1 ]] && sig="<name>-sig.json"
  sign_cmds+="
       gnokey sign -tx-path $f -chainid $CHAIN_ID -account-number ${acct_num:-N} -account-sequence $seq \\
           -output-document $sig <signer-key>"
  multisign_cmds+="
       gnokey multisign -tx-path $f -signature ${sig/<name>/<a>} -signature ${sig/<name>/<b>} <multisig-key>"
  broadcast_cmds+="
       gnokey broadcast -remote $REMOTE $f"
done
order_note=""
if [[ "${#TX_FILES[@]}" -gt 1 ]]; then
  order_note=" one at a time, in this order (each needs the packages of the ones before it,
     and its sequence follows theirs)"
fi

cat <<EOT

==> Next steps (multisig flow; account number/sequence are those of the creator $creator_addr right now:
    account-number=${acct_num:-?} account-sequence=${acct_seq:-?}; re-check before signing if another tx was sent meanwhile)

  1. Each signer, on their own machine, with the shared ${TX_FILES[*]}:${sign_cmds}
  2. Whoever holds the multisig key combines the signatures (member order matters, see the gno docs):${multisign_cmds}
  3. Broadcast${order_note}:${broadcast_cmds}
  4. On an "inert" chain the packages park until the approvers enable them; poll with
       gnokey query vm/qpkgmeta_json -data <pkgpath> -remote $REMOTE   (status: inert -> live)
  5. Once core and ibcgov are live, governance adds the relayers: until the first add-relayer
     decision executes the whitelist is empty and any address may create clients and relay (see
     gno.land/r/aib/ibc/core/README.md, "Relayer whitelist"). core.AddRelayer accepts ibcgov only,
     so a direct call panics. The ibcgov governor (the creator $creator_addr, before its yield) records the
     decisions with a MsgRun${RELAYERS_HINT}:
       gnokey maketx run -gas-fee ... -gas-wanted ... -broadcast -chainid $CHAIN_ID -remote $REMOTE \\
           <governor-key> ${RELAYERS_FILE}
     After the yield a GovDAO proposal of the same requests replaces it.
     Each decision is queued for 7 days (production); then anyone applies it with its number
     (gno.land/r/aib/ibc/ibcgov:decisions):
       gnokey maketx call -pkgpath gno.land/r/aib/ibc/ibcgov -func Execute -args <decision> ... <any-key>
EOT
