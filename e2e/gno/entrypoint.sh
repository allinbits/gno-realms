#!/bin/bash
set -eu

echo "Starting gnodev..."

# Pre-fund the test account derived from TEST_MNEMONIC
# Address: g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x
# (same key as atone1z437dpuh5s4p64vtq09dulg6jzxpr2hdgu88r6 on AtomOne)
TEST_ADDR="g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x"

# Derive relayer address from RELAYER_MNEMONIC
printf "%s\n\n" "$RELAYER_MNEMONIC" | gnokey add relayer --recover --insecure-password-stdin --force 2>&1
RELAYER_ADDR=$(gnokey list 2>&1 | grep relayer | sed 's/.*addr: \([^ ]*\).*/\1/')
echo "Relayer address: $RELAYER_ADDR"

# Run from the workspace so gnodev auto-detects it (gnowork.toml); GNOROOT is a
# writable checkout, so stdlibs/examples and the node config resolve from it.
cd /aibgno

# Every package a test transaction imports must be preloaded in -paths:
# gnodev's lazy loader reloads the node when a transaction references a
# package it has not loaded yet, which resets the chain under the relayer and
# invalidates the light client AtomOne keeps of it. r/gov/dao/init/v0 is what
# the upgrade tests use to seed the GovDAO.
exec gnodev local \
    -node-rpc-listener 0.0.0.0:26657 \
    -web-listener 0.0.0.0:8888 \
    -web-help-remote http://127.0.0.1:26657 \
    -empty-blocks \
    -no-watch \
    -add-account "${TEST_ADDR}=10000000000ugnot" \
    -add-account "${RELAYER_ADDR}=10000000000ugnot" \
    -paths "gno.land/r/aib/ibc/core,gno.land/r/aib/ibc/core/impl/v0,gno.land/r/aib/ibc/apps/transfer,gno.land/r/aib/ibc/apps/transfer/impl/v0,gno.land/r/aib/ibc/apps/testing/grc20test,gno.land/r/gov/dao/init/v0"
