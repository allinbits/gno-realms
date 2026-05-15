#!/usr/bin/env bash
#
# Deploy all aibgno packages and realms to gno.land test13.
#
# Packages are listed in topological dependency order — each entry only
# imports from entries above it. Edit START_AT to resume after a failure.
#
# Usage:
#   ./scripts/deploy-test13.sh                # deploy all
#   START_AT=10 ./scripts/deploy-test13.sh    # resume from entry 10 (1-based)
#   DRY_RUN=1 ./scripts/deploy-test13.sh      # simulate only, no broadcast

set -euo pipefail

# ---- config -----------------------------------------------------------------

KEY="${KEY:-aib}"
CHAIN_ID="${CHAIN_ID:-test-13}"
REMOTE="${REMOTE:-https://rpc.test-13-aeddi-1.gnoland.network:443}"
GAS_FEE="${GAS_FEE:-1000000ugnot}"
GAS_WANTED="${GAS_WANTED:-200000000}"
MAX_DEPOSIT="${MAX_DEPOSIT:-100000000ugnot}"
START_AT="${START_AT:-1}"
DRY_RUN="${DRY_RUN:-0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ---- deploy order -----------------------------------------------------------
# Format: "<gno.land/pkgpath>:<local dir relative to repo root>"
# Order is topological: a package only depends on entries above it.
PACKAGES=(
  # leaf packages (no aib deps)
  "gno.land/p/aib/encoding:gno.land/p/aib/encoding"
  "gno.land/p/aib/encoding/proto:gno.land/p/aib/encoding/proto"
  "gno.land/p/aib/merkle:gno.land/p/aib/merkle"
  "gno.land/p/aib/jsonpage:gno.land/p/aib/jsonpage"
  "gno.land/p/aib/ibc/host:gno.land/p/aib/ibc/host"

  # depends on encoding/proto
  "gno.land/p/aib/ics23:gno.land/p/aib/ics23"

  # depends on ics23
  "gno.land/p/aib/ibc/testing:gno.land/p/aib/ibc/testing"

  # depends on encoding, encoding/proto, ibc/host, ics23
  "gno.land/p/aib/ibc/types:gno.land/p/aib/ibc/types"

  # depends on ibc/types
  "gno.land/p/aib/ibc/app:gno.land/p/aib/ibc/app"

  # depends on ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient:gno.land/p/aib/ibc/lightclient"

  # depends on encoding/proto, ibc/lightclient, ibc/types, ics23, merkle
  "gno.land/p/aib/ibc/lightclient/tendermint:gno.land/p/aib/ibc/lightclient/tendermint"

  # depends on lightclient/tendermint, ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient/tendermint/testing:gno.land/p/aib/ibc/lightclient/tendermint/testing"

  # realms (stateful)
  # grc20test has no aib deps
  "gno.land/r/aib/ibc/apps/testing/grc20test:gno.land/r/aib/ibc/apps/testing/grc20test"

  # depends on ibc/app, ibc/types
  "gno.land/r/aib/ibc/apps/testing:gno.land/r/aib/ibc/apps/testing"

  # depends on ibc/app, ibc/host, ibc/lightclient, lightclient/tendermint,
  # lightclient/tendermint/testing (filetest), ibc/types, ics23, jsonpage
  "gno.land/r/aib/ibc/core:gno.land/r/aib/ibc/core"

  # depends on encoding/proto, ibc/app, ibc/host, lightclient/tendermint,
  # ibc/types, ics23, jsonpage, grc20test (filetest), r/aib/ibc/core
  "gno.land/r/aib/ibc/apps/transfer:gno.land/r/aib/ibc/apps/transfer"
)

# ---- helpers ----------------------------------------------------------------

SIMULATE_FLAG="test"
BROADCAST_FLAG="-broadcast"
if [[ "$DRY_RUN" == "1" ]]; then
  SIMULATE_FLAG="only"
fi

echo "==> Deploying ${#PACKAGES[@]} packages to $CHAIN_ID ($REMOTE)"
echo "    key=$KEY  gas-fee=$GAS_FEE  gas-wanted=$GAS_WANTED  max-deposit=$MAX_DEPOSIT"
echo "    starting at entry $START_AT  dry-run=$DRY_RUN"
echo

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

  gnokey maketx addpkg \
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

  echo
done

echo "==> Done."
