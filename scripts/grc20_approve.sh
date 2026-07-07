#!/usr/bin/env bash
#
# Set an allowance on the grc20test ("TEST") token on gno.land test13.
#
# grc20test.Approve is test-only and has NO caller authorization, so any signed
# tx can set an allowance for any owner->spender pair (the owner is passed
# explicitly, it need not be the signing key).
#
# Override via env: KEY, CHAIN_ID, REMOTE, PKGPATH, OWNER, SPENDER, AMOUNT,
#   GAS_FEE, GAS_WANTED.
#
# Usage:
#   SPENDER=g1... ./scripts/grc20_approve.sh
#   OWNER=g1... SPENDER=g1... AMOUNT=100 ./scripts/grc20_approve.sh

set -euo pipefail

KEY="${KEY:-aib}"
CHAIN_ID="${CHAIN_ID:-test-13}"
REMOTE="${REMOTE:-https://rpc.test13.testnets.gno.land/}"
PKGPATH="${PKGPATH:-gno.land/r/aib/ibc/apps/testing/grc20test}"
OWNER="${OWNER:-g12j6x2cnpkvz83l6a5lhfw22703kwwpknpfnt70}" # aib
SPENDER="${SPENDER:-g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00}" # transfer realm (DerivePkgAddr gno.land/r/aib/ibc/apps/transfer)
AMOUNT="${AMOUNT:-1000000}"
GAS_FEE="${GAS_FEE:-1000000ugnot}"
GAS_WANTED="${GAS_WANTED:-10000000}"

echo "==> Approve $AMOUNT TEST: owner=$OWNER spender=$SPENDER"
echo "    pkgpath=$PKGPATH chainid=$CHAIN_ID remote=$REMOTE key=$KEY"
echo

# Ask the key password once, then feed it via -insecure-password-stdin.
read -rsp "Password for key '$KEY': " GNOKEY_PASSWORD
echo; echo

printf '%s\n' "$GNOKEY_PASSWORD" | gnokey maketx call \
	-insecure-password-stdin \
	-pkgpath "$PKGPATH" \
	-func Approve \
	-args "$OWNER" \
	-args "$SPENDER" \
	-args "$AMOUNT" \
	-gas-fee "$GAS_FEE" \
	-gas-wanted "$GAS_WANTED" \
	-broadcast \
	-chainid "$CHAIN_ID" \
	-remote "$REMOTE" \
	"$KEY"

echo
echo "==> Allowance after:"
gnokey query vm/qeval \
	--data "$PKGPATH.Allowance(\"$OWNER\",\"$SPENDER\")" \
	-remote "$REMOTE"
