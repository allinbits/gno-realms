# Shared gno.land target for the scripts in this directory. Sourced, never
# executed:
#
#   source "$(dirname "$0")/env.sh"
#
# Migrating every script to the next testnet is a one-line edit here (the
# chain id and RPC host both derive from the testnet name). Every value stays
# env-overridable, so a one-off run against another chain needs no edit:
#
#   GNO_TESTNET=pearl ./scripts/grc20_balance.sh
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

# onyx (chain-id onyx-1, launched 2026-09-28) runs mainnet's policies: the
# vm code_submission_policy is "inert", so every addpkg parks until the gpao
# approvals oracle enables it (deploy.sh waits for that), and run_submitters is
# restricted, so `maketx run` only works for allowlisted accounts — the IBC
# core's MsgRun entry points, and so the relayer key, need that allowlisting
# (propose-run-submitter.sh creates the GovDAO proposal for it).
# The `aib` namespace has to be owned on each new chain (see deploy.sh).
GNO_TESTNET="${GNO_TESTNET:-onyx}"
CHAIN_ID="${CHAIN_ID:-${GNO_TESTNET}-1}"
REMOTE="${REMOTE:-https://rpc.${GNO_TESTNET}.testnets.gno.land:443}"
KEY="${KEY:-aib}"

# The AIB multisig: creator of the realms (make-deploy-tx.sh) and their admin
# at bootstrap. It must own the `aib` namespace on the target chain.
MULTISIG_ADDR="${MULTISIG_ADDR:-g1gkqe9c90tfuk2a7f07ygs8t826aff03vxasjsl}"
