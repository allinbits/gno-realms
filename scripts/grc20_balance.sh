#!/usr/bin/env bash
#
# Query an IBC voucher balance on gno.land.
#
# The voucher's IBC denom is derived from CLIENT_ID + BASE_DENOM rather than
# hardcoded, so it does not go stale when the counterparty client changes with
# the testnet: ibc/<uppercase-hex SHA256 of the trace>. Its balance is read
# through the transfer app (VoucherBalanceOf). A voucher's grc20reg key is
# "<rlmPath>.<symbol>" with a symbol allocated when the voucher is created
# (IBC-1, IBC-2, ...), so it cannot be derived from the hash: pass GRC20KEY
# (from the voucher/ibc/<hash> render's grc20reg_key) to read the registry
# instead. For example, on pearl:
#   SHA256("transfer/07-tendermint-2/uatone") = 542B346608DE0327… -> ibc/542B346608DE0327…
#
# Override any layer:
#   CLIENT_ID=07-tendermint-1 ./scripts/grc20_balance.sh
#   BASE_DENOM=uphoton ./scripts/grc20_balance.sh
#   GRC20KEY=gno.land/r/aib/ibc/apps/transfer.IBC-1 ./scripts/grc20_balance.sh

set -euox pipefail

source "$(dirname "$0")/env.sh"

ADDR="${ADDR:-g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x}" # relayer
CLIENT_ID="${CLIENT_ID:-07-tendermint-2}" # last known (pearl, counterparty of 10-gno-16); no client exists on onyx yet, set it once the relayer created one
BASE_DENOM="${BASE_DENOM:-uatone}"
IBC_HASH=$(printf 'transfer/%s/%s' "$CLIENT_ID" "$BASE_DENOM" |
	sha256sum | cut -c1-64 | tr '[:lower:]' '[:upper:]')

if [ -n "${GRC20KEY:-}" ]; then
	"${GNOKEY_CMD[@]}" query vm/qeval \
		--data "gno.land/r/nt/grc20reg/v0.MustGet(\"$GRC20KEY\").BalanceOf(\"$ADDR\")" \
		-remote $REMOTE
else
	"${GNOKEY_CMD[@]}" query vm/qeval \
		--data "gno.land/r/aib/ibc/apps/transfer.VoucherBalanceOf(\"ibc/$IBC_HASH\", \"$ADDR\")" \
		-remote $REMOTE
fi
