#!/bin/bash
set -eu

# Derive relayer address from RELAYER_MNEMONIC
printf "%s\n\n" "$RELAYER_MNEMONIC" | gnokey add relayer --recover --insecure-password-stdin --force 2>&1
RELAYER_ADDR=$(gnokey list 2>&1 | grep relayer | sed 's/.*addr: \([^ ]*\).*/\1/')
echo "Relayer address: $RELAYER_ADDR"

# Adding a relayer is an ibcgov decision (ADR pr6375 R14): the core takes it
# only from gno.land/r/aib/ibc/ibcgov. The devnet build makes the e2e test key
# (TEST_MNEMONIC) the launch governor and a 7-day delay 10 s (see
# e2e/gno/Dockerfile): the governor records the decision, then anyone executes
# it once due.
printf "%s\n\n" "$TEST_MNEMONIC" | gnokey add governor --recover --insecure-password-stdin --force 2>&1

run() {
    printf "\n" | gnokey maketx run \
        -gas-fee 1000000ugnot \
        -gas-wanted 90000000 \
        -broadcast \
        -chainid dev \
        -remote gno:26657 \
        -insecure-password-stdin \
        governor "$1"
}

cat > /tmp/decide.gno <<GNO
package main

import (
	"gno.land/r/aib/ibc/ibcgov"
)

func main(cur realm) {
	ibcgov.Govern(cross(cur), ibcgov.NewCoreAddRelayerRequest(cross(cur), "$RELAYER_ADDR"))
}
GNO
cat > /tmp/execute.gno <<'GNO'
package main

import (
	"gno.land/r/aib/ibc/ibcgov"
)

func main(cur realm) {
	ibcgov.Execute(cross(cur), ibcgov.LastDecision())
}
GNO

echo "Deciding to whitelist relayer $RELAYER_ADDR on gno:26657..."
run /tmp/decide.gno
sleep 12
run /tmp/execute.gno

echo "Relayer $RELAYER_ADDR whitelisted"
