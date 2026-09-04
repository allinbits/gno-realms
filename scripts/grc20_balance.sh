#!/usr/bin/env bash
#
# Query an IBC voucher balance on gno.land.
#
# GRC20KEY is derived from CLIENT_ID + BASE_DENOM rather than hardcoded, so it
# does not go stale when the counterparty client changes with the testnet:
# grc20reg keys tokens by "<rlmPath>.<symbol>", and a voucher's symbol is the
# uppercase-hex SHA256 of its trace truncated to grc20.MaxSymbolLen (11) — not
# the full hash. On pearl:
#   SHA256("transfer/07-tendermint-2/uatone") = 542B346608DE0327… -> 542B346608D
#
# Override any layer:
#   CLIENT_ID=07-tendermint-1 ./scripts/grc20_balance.sh
#   BASE_DENOM=uphoton ./scripts/grc20_balance.sh
#   GRC20KEY=gno.land/r/aib/ibc/apps/transfer.ABC12345678 ./scripts/grc20_balance.sh

set -euox pipefail

source "$(dirname "$0")/env.sh"

ADDR="${ADDR:-g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x}" # relayer
CLIENT_ID="${CLIENT_ID:-07-tendermint-2}" # counterparty of 10-gno-16 on pearl
BASE_DENOM="${BASE_DENOM:-uatone}"
VOUCHER_SYMBOL=$(printf 'transfer/%s/%s' "$CLIENT_ID" "$BASE_DENOM" |
	sha256sum | cut -c1-11 | tr '[:lower:]' '[:upper:]')
GRC20KEY="${GRC20KEY:-gno.land/r/aib/ibc/apps/transfer.$VOUCHER_SYMBOL}"

"${GNOKEY_CMD[@]}" query vm/qeval \
	--data "gno.land/r/demo/defi/grc20reg.MustGet(\"$GRC20KEY\").BalanceOf(\"$ADDR\")" \
	-remote $REMOTE
