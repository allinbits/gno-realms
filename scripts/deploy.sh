#!/usr/bin/env bash
#
# Deploy all aibgno packages and realms to gno.land (target: see env.sh).
#
# Packages are listed in topological dependency order — each entry only
# imports from entries above it. Edit START_AT to resume after a failure.
#
# Usage:
#   ./scripts/deploy.sh                # deploy all
#   START_AT=10 ./scripts/deploy.sh    # resume from entry 10 (1-based)
#   DRY_RUN=1 ./scripts/deploy.sh      # simulate only, no broadcast
#
# On a chain whose vm code_submission_policy is "inert" (gno.land mainnet),
# addpkg only parks a package: it is stored without being type-checked or
# executed, and becomes live when a package approver sends MsgEnablePackage.
# The script then ends by polling until every package is live (see
# ENABLE_POLL_INTERVAL); Ctrl-C stops the waiting, the packages stay parked.
#
# Prerequisites on a freshly launched testnet
# -------------------------------------------
#   1. $KEY must be funded: every addpkg pays $GAS_FEE and locks storage out
#      of $MAX_DEPOSIT, times ${#PACKAGES[@]} entries.
#      Faucet: https://faucet.gno.land (pick the target testnet).
#
#   2. $KEY must own the `aib` namespace, otherwise the very first addpkg is
#      rejected by r/sys/names (enforcement is on: `IsEnabled() == true`).
#      Check with:
#        gnokey query vm/qeval -remote "$REMOTE" \
#          -data 'gno.land/r/sys/users.ResolveName("aib")'
#      and compare the returned address to `gnokey list`.
#      r/sys/namereg/v1.Register only self-serves `nym-<stem><3 digits>`
#      names, so a vanity namespace such as `aib` has to be granted by
#      GovDAO (ProposeNewName) — or the packages deployed under the
#      deployer's own address namespace (gno.land/{p,r}/<g1address>/...),
#      which means rewriting every pkgpath and import.

set -euo pipefail

# ---- config -----------------------------------------------------------------

source "$(dirname "$0")/env.sh"

GAS_FEE="${GAS_FEE:-6000000ugnot}"
GAS_WANTED="${GAS_WANTED:-1000000000}"
MAX_DEPOSIT="${MAX_DEPOSIT:-100000000ugnot}"
START_AT="${START_AT:-1}"
DRY_RUN="${DRY_RUN:-0}"
ENABLE_POLL_INTERVAL="${ENABLE_POLL_INTERVAL:-30}" # seconds, inert policy only

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ---- deploy order -----------------------------------------------------------
# PACKAGES comes from packages.sh, shared with make-deploy-tx.sh.
source "$(dirname "$0")/packages.sh"

# ---- helpers ----------------------------------------------------------------

# pkg_status prints the on-chain status of a package path, as reported by
# vm/qpkgmeta_json: "live" (deployed and callable), "inert" (submitted, parked,
# awaiting a package approver) or "absent" (nothing at this path). Empty when
# the query itself fails.
pkg_status() {
  "${GNOKEY_CMD[@]}" query vm/qpkgmeta_json -data "$1" -remote "$REMOTE" 2>/dev/null \
    | sed -n 's/^data: //p' | grep -o '"status":"[a-z]*"' | cut -d'"' -f4
}

# code_submission_policy prints the chain's vm code-submission policy:
# "permissionless", "permissioned" or "inert". Empty when the query fails.
code_submission_policy() {
  "${GNOKEY_CMD[@]}" query params/vm:p:code_submission_policy -remote "$REMOTE" 2>/dev/null \
    | sed -n 's/^data: //p' | tr -d '"'
}

SIMULATE_FLAG="test"
BROADCAST_FLAG="-broadcast"
if [[ "$DRY_RUN" == "1" ]]; then
  SIMULATE_FLAG="only"
fi

echo "==> Deploying ${#PACKAGES[@]} packages to $CHAIN_ID ($REMOTE)"
echo "    key=$KEY  gas-fee=$GAS_FEE  gas-wanted=$GAS_WANTED  max-deposit=$MAX_DEPOSIT"
echo "    starting at entry $START_AT  dry-run=$DRY_RUN"
echo

# Ask the key password once, then feed it to every gnokey invocation via
# -insecure-password-stdin instead of prompting interactively each time.
read -rsp "Password for key '$KEY': " GNOKEY_PASSWORD
echo; echo

i=0
for entry in "${PACKAGES[@]}"; do
  i=$((i + 1))
  pkgpath="${entry%%:*}"
  pkgdir="${entry##*:}"

  if (( i < START_AT )); then
    printf "  [%2d/%2d] skip   %s\n" "$i" "${#PACKAGES[@]}" "$pkgpath"
    continue
  fi

  printf "==> [%2d/%2d] %s\n" "$i" "${#PACKAGES[@]}" "$pkgpath"
  printf "          dir: %s\n" "$pkgdir"

  if [[ ! -d "$pkgdir" ]]; then
    echo "    ERROR: directory not found: $pkgdir" >&2
    exit 1
  fi

  printf '%s\n' "$GNOKEY_PASSWORD" | "${GNOKEY_CMD[@]}" maketx addpkg \
    -insecure-password-stdin \
    -pkgpath "$pkgpath" \
    -pkgdir "$pkgdir" \
    -gas-fee "$GAS_FEE" \
    -gas-wanted "$GAS_WANTED" \
    -max-deposit "$MAX_DEPOSIT" \
    -simulate "$SIMULATE_FLAG" \
    $BROADCAST_FLAG \
    -chainid "$CHAIN_ID" \
    -remote "$REMOTE" \
    "$KEY"

  # BroadcastTxCommit returns slightly before the next-block state is
  # queryable, so the next tx could be signed with a stale account sequence
  # ("signature verification failed"). Wait until the package is on chain
  # (same committed state as the account sequence) before moving on. Under the
  # "inert" policy the package is only parked at this point ("inert", not
  # "live"); the final loop below waits for its enablement.
  if [[ "$DRY_RUN" != "1" ]]; then
    for attempt in $(seq 1 30); do
      status="$(pkg_status "$pkgpath")"
      if [[ "$status" == "live" || "$status" == "inert" ]]; then
        printf "          status: %s\n" "$status"
        break
      fi
      if (( attempt == 30 )); then
        echo "    ERROR: $pkgpath still not on chain after ${attempt}s (status: ${status:-unknown})" >&2
        exit 1
      fi
      sleep 1
    done
  fi

  echo
done

# ---- enablement -------------------------------------------------------------
# Under the "inert" code-submission policy, addpkg only parks a package; a
# package approver has to send MsgEnablePackage for it to be type-checked,
# initialised and callable. Each package's init() (for instance the transfer
# realm's core.RegisterApp) runs at that moment, in the approver's order. Only
# report the deploy done once every package is live.
if [[ "$DRY_RUN" != "1" ]]; then
  policy="$(code_submission_policy)"
  echo "==> code_submission_policy: ${policy:-unknown}"
  if [[ "$policy" == "inert" ]]; then
    echo "==> Waiting for package approvers to enable the packages"
    echo "    (polling every ${ENABLE_POLL_INTERVAL}s; Ctrl-C stops waiting, the packages stay parked)"
    while true; do
      pending=()
      for entry in "${PACKAGES[@]}"; do
        pkgpath="${entry%%:*}"
        status="$(pkg_status "$pkgpath")"
        if [[ "$status" != "live" ]]; then
          pending+=("$pkgpath (${status:-unknown})")
        fi
      done
      if (( ${#pending[@]} == 0 )); then
        echo "==> All ${#PACKAGES[@]} packages are live."
        break
      fi
      echo "    $(date +%H:%M:%S) ${#pending[@]}/${#PACKAGES[@]} not live yet:"
      printf "      %s\n" "${pending[@]}"
      sleep "$ENABLE_POLL_INTERVAL"
    done
  fi
fi

echo "==> Done."
