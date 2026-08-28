# Shared gno.land target for the scripts in this directory. Sourced, never
# executed:
#
#   source "$(dirname "$0")/env.sh"
#
# Migrating every script to the next testnet is a one-line edit here (the
# chain id and RPC host both derive from the testnet name). Every value stays
# env-overridable, so a one-off run against another chain needs no edit:
#
#   GNO_TESTNET=sapphire ./scripts/grc20_balance.sh
#   CHAIN_ID=dev REMOTE=http://127.0.0.1:26657 ./scripts/deploy.sh
#   GNOKEY=gnokey ./scripts/deploy.sh
#
# Not used by transfer-atomone-to-gno.sh: its CHAIN_ID/NODE describe the
# AtomOne side, not gno.

# gnokey built from the gno commit go.mod pins, not whatever `gnokey` is on
# $PATH. A stale binary silently signs the wrong bytes: gnokey raises GasWanted
# to consensus max before simulating, and since RequireSigForSimulate the chain
# verifies signatures on the simulate path for code-bearing messages
# (add_package, run) — a client that predates that gate does not re-sign the
# rewritten tx, so every addpkg dies in simulation with "signature verification
# failed; verify correct account, sequence, and chain-id".
# `go -C` so it resolves the module from any cwd. Override with GNOKEY=gnokey.
GNOKEY="${GNOKEY:-go -C $(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) tool gnokey}"
read -r -a GNOKEY_CMD <<<"$GNOKEY"

GNO_TESTNET="${GNO_TESTNET:-pearl}"
CHAIN_ID="${CHAIN_ID:-${GNO_TESTNET}-1}"
REMOTE="${REMOTE:-https://rpc.${GNO_TESTNET}.testnets.gno.land:443}"
KEY="${KEY:-aib}"
