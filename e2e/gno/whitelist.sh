#!/bin/bash
set -eu

# Derive relayer address from RELAYER_MNEMONIC
printf "%s\n\n" "$RELAYER_MNEMONIC" | gnokey add relayer --recover --insecure-password-stdin --force 2>&1
RELAYER_ADDR=$(gnokey list 2>&1 | grep relayer | sed 's/.*addr: \([^ ]*\).*/\1/')
echo "Relayer address: $RELAYER_ADDR"

# gnodev always deploys realms with the test1 account as DefaultCreator, so
# test1 becomes the core realm admin after init(). Use it to whitelist the
# relayer address.
TEST1_SEED="source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast"
printf "%s\n\n" "$TEST1_SEED" | gnokey add test1 --recover --insecure-password-stdin --force 2>&1

cat > /tmp/whitelist-relayer.gno << EOF
package main

import "gno.land/r/aib/ibc/core"

func main() {
    core.AddRelayer(cross, "$RELAYER_ADDR")
}
EOF

echo "Whitelisting relayer $RELAYER_ADDR on gno:26657..."
printf "\n" | gnokey maketx run \
    -gas-fee 1000000ugnot \
    -gas-wanted 90000000 \
    -broadcast \
    -chainid dev \
    -remote gno:26657 \
    -insecure-password-stdin \
    test1 \
    /tmp/whitelist-relayer.gno

echo "Relayer $RELAYER_ADDR whitelisted"
