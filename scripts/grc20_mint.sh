#!/usr/bin/env bash
#
# Mint grc20test ("TEST") tokens to an address on gno.land test13.
#
# grc20test.Mint is test-only and has NO caller authorization, so any signed
# tx can mint to any address.
#
# Override via env: KEY, CHAIN_ID, REMOTE, PKGPATH, TO, AMOUNT,
#   GAS_FEE, GAS_WANTED.
#
# Usage:
#   ./scripts/grc20_mint.sh
#   TO=g1... AMOUNT=1000000 ./scripts/grc20_mint.sh

set -euo pipefail

KEY="${KEY:-aib}"
CHAIN_ID="${CHAIN_ID:-test-13}"
REMOTE="${REMOTE:-https://rpc.test13.testnets.gno.land/}"
PKGPATH="${PKGPATH:-gno.land/r/aib/ibc/apps/testing/grc20test}"
TO="${TO:-g12j6x2cnpkvz83l6a5lhfw22703kwwpknpfnt70}" # aib
AMOUNT="${AMOUNT:-1000000}"
GAS_FEE="${GAS_FEE:-1000000ugnot}"
GAS_WANTED="${GAS_WANTED:-10000000}"

echo "==> Mint $AMOUNT TEST to $TO"
echo "    pkgpath=$PKGPATH chainid=$CHAIN_ID remote=$REMOTE key=$KEY"
echo

# Ask the key password once, then feed it via -insecure-password-stdin.
read -rsp "Password for key '$KEY': " GNOKEY_PASSWORD
echo; echo

printf '%s\n' "$GNOKEY_PASSWORD" | gnokey maketx call \
	-insecure-password-stdin \
	-pkgpath "$PKGPATH" \
	-func Mint \
	-args "$TO" \
	-args "$AMOUNT" \
	-gas-fee "$GAS_FEE" \
	-gas-wanted "$GAS_WANTED" \
	-broadcast \
	-chainid "$CHAIN_ID" \
	-remote "$REMOTE" \
	"$KEY"

echo
echo "==> Balance after:"
gnokey query vm/qeval \
	--data "$PKGPATH.BalanceOf(\"$TO\")" \
	-remote "$REMOTE"
