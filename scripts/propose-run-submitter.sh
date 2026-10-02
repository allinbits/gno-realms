#!/usr/bin/env bash
#
# Create the GovDAO proposal that adds an address (by default the relayer) to
# vm:p:run_submitters, the allowlist of accounts allowed to send MsgRun.
#
# Why: chains that restrict run_submitters (onyx, mainnet) reject MsgRun from
# any other account, and the IBC core's entry points take complex arguments
# that only MsgRun can carry. Without this the relayer's CreateClient,
# UpdateClient and packet transactions are all refused.
#
# How: r/sys/params reserves the key for ProposeSetRunSubmitters, which
# replaces the WHOLE list and refuses a list that omits the proposer (a list
# naming nobody who can propose could never be changed back). The run script
# below therefore reads the current list on-chain, appends the new address
# (and the proposer, if the gate was off and the list empty), and submits the
# proposal through r/gov/dao. Proposer requirements: a GovDAO member, and
# already a run submitter, since creating a proposal is itself a MsgRun.
#
# Once created, members vote and anyone executes (both plain MsgCall):
#   gnokey maketx call -pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple \
#       -args <pid> -args YES -gas-fee 1000000ugnot -gas-wanted 20000000 \
#       -broadcast -chainid <chain-id> -remote <rpc> <member-key>
#   gnokey maketx call -pkgpath gno.land/r/gov/dao -func ExecuteProposal \
#       -args <pid> -gas-fee 1000000ugnot -gas-wanted 20000000 \
#       -broadcast -chainid <chain-id> -remote <rpc> <any-key>
#
# Usage:
#   ./scripts/propose-run-submitter.sh                        # adds $RELAYER_ADDR
#   RELAYER_ADDR=g1... KEY=mykey ./scripts/propose-run-submitter.sh
#   DRY_RUN=1 ./scripts/propose-run-submitter.sh              # simulate only
#   PRINT_ONLY=1 ./scripts/propose-run-submitter.sh           # show the run script, send nothing

set -euo pipefail

source "$(dirname "$0")/env.sh"

# The relayer key: the account the e2e suite and the testnet relayer sign
# with (TEST_MNEMONIC), also the default ADDR of grc20_balance.sh.
RELAYER_ADDR="${RELAYER_ADDR:-g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x}"
GAS_FEE="${GAS_FEE:-1000000ugnot}"
GAS_WANTED="${GAS_WANTED:-50000000}"
DRY_RUN="${DRY_RUN:-0}"
PRINT_ONLY="${PRINT_ONLY:-0}"

if [[ ! "$RELAYER_ADDR" =~ ^g1[a-z0-9]{38}$ ]]; then
  echo "ERROR: RELAYER_ADDR does not look like a gno address: $RELAYER_ADDR" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT
RUN_FILE="$RUN_DIR/run.gno"

cat > "$RUN_FILE" <<GNO
package main

import (
	"gno.land/r/gov/dao"
	"gno.land/r/sys/params"
)

const newSubmitter = "$RELAYER_ADDR"

func main(cur realm) {
	addrs := params.GetRunSubmitters()
	for _, a := range addrs {
		if a == newSubmitter {
			panic("already a run submitter: " + newSubmitter)
		}
	}
	addrs = append(addrs, newSubmitter)

	// ProposeSetRunSubmitters refuses a list that omits the proposer. The
	// proposer is on the current list whenever the gate is on (they just sent
	// this MsgRun); if the gate is off (empty list) they must be added too.
	proposer := cur.Previous().Address().String()
	listed := false
	for _, a := range addrs {
		if a == proposer {
			listed = true
			break
		}
	}
	if !listed {
		addrs = append(addrs, proposer)
	}

	req := params.ProposeSetRunSubmitters(cross(cur), addrs)
	pid := dao.MustCreateProposal(cross(cur), req)
	println("proposal created:", int64(pid))
	println("run_submitters once executed:")
	for _, a := range addrs {
		println("  " + a)
	}
}
GNO

if [[ "$PRINT_ONLY" == "1" ]]; then
  cat "$RUN_FILE"
  exit 0
fi

SIMULATE_FLAG="test"
BROADCAST_FLAG="-broadcast"
if [[ "$DRY_RUN" == "1" ]]; then
  SIMULATE_FLAG="only"
  BROADCAST_FLAG=""
fi

echo "==> Proposing to add $RELAYER_ADDR to vm:p:run_submitters on $CHAIN_ID ($REMOTE)"
echo "    proposer key=$KEY  gas-fee=$GAS_FEE  gas-wanted=$GAS_WANTED  dry-run=$DRY_RUN"
echo "    current run_submitters:"
"${GNOKEY_CMD[@]}" query vm/qeval -data 'gno.land/r/sys/params.GetRunSubmitters()' -remote "$REMOTE" \
  | sed -n 's/^data: //p' | grep -o 'g1[a-z0-9]\{38\}' | sed 's/^/      /' || true
echo

"${GNOKEY_CMD[@]}" maketx run \
  -gas-fee "$GAS_FEE" \
  -gas-wanted "$GAS_WANTED" \
  -simulate "$SIMULATE_FLAG" \
  $BROADCAST_FLAG \
  -chainid "$CHAIN_ID" \
  -remote "$REMOTE" \
  "$KEY" "$RUN_FILE"
