#!/usr/bin/env bash
#
# Query an IBC voucher balance on gno.land.
#
# GRC20KEY defaults to the uatone voucher received over 07-tendermint-X.
# grc20reg keys tokens by "<rlmPath>.<symbol>", and a voucher's symbol is the
# IBC hash truncated to grc20.MaxSymbolLen (11) — not the full hash. Here:
#   SHA256("transfer/07-tendermint-1/uatone") = F9A67CB19B2CAD2A… -> F9A67CB19B2

set -euox pipefail

ADDR="${ADDR:-g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x}" # relayer
REMOTE="${REMOTE:-https://rpc.sapphire.testnets.gno.land:443}"
GRC20KEY="${GRC20KEY:-gno.land/r/aib/ibc/apps/transfer.F9A67CB19B2}"

gnokey query vm/qeval \
	--data "gno.land/r/demo/defi/grc20reg.MustGet(\"$GRC20KEY\").BalanceOf(\"$ADDR\")" \
	-remote $REMOTE
