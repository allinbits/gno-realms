#!/bin/bash
set -eu

CHAIN_ID="${ATOMONE_CHAIN_ID:-atomone-e2e-1}"
MONIKER="validator"

echo "Initializing AtomOne chain ($CHAIN_ID)..."

# Initialize the chain (overwrite if re-run)
atomoned init "$MONIKER" --chain-id "$CHAIN_ID" --default-denom uatone --home /root/.atomone -o

# Recover the validator key from the test mnemonic
echo "$TEST_MNEMONIC" | atomoned keys add validator --recover --keyring-backend test --home /root/.atomone

VALIDATOR_ADDR=$(atomoned keys show validator -a --keyring-backend test --home /root/.atomone)
echo "Validator address: $VALIDATOR_ADDR"

# Fund the validator account in genesis
atomoned genesis add-genesis-account "$VALIDATOR_ADDR" "1000000000uatone,10000000000uphoton" --keyring-backend test --home /root/.atomone

# Create the gentx
atomoned genesis gentx validator "500000000uatone" \
    --chain-id "$CHAIN_ID" \
    --keyring-backend test \
    --home /root/.atomone

# Collect gentxs
atomoned genesis collect-gentxs --home /root/.atomone

# Configure for fast blocks and external access
CONFIG_DIR=/root/.atomone/config

# Patch genesis: the feat/gno-lc branch has a photon module that enforces
# uphoton fees. Add IBC message types to fee exceptions so uatone fees also work.
GENESIS="$CONFIG_DIR/genesis.json"
jq '
    # Add IBC message types to photon tx_fee_exceptions
    .app_state.photon.params.tx_fee_exceptions += [
        "/ibc.core.client.v1.MsgCreateClient",
        "/ibc.core.client.v1.MsgUpdateClient",
        "/ibc.core.channel.v2.MsgSendPacket",
        "/ibc.core.channel.v2.MsgRecvPacket",
        "/ibc.core.channel.v2.MsgAcknowledgement",
        "/ibc.core.channel.v2.MsgTimeout",
        "/ibc.core.channel.v2.MsgRegisterCounterparty"
    ] |
    # Set low dynamicfee base gas price
    .app_state.dynamicfee.params.min_base_gas_price = "0.000010000000000000" |
    .app_state.dynamicfee.state.base_gas_price = "0.000010000000000000"
' "$GENESIS" > /tmp/genesis_patched.json && mv /tmp/genesis_patched.json "$GENESIS"

# app.toml: enable REST API, gRPC, and set minimum gas prices
sed -i 's/enable = false/enable = true/g' "$CONFIG_DIR/app.toml"
sed -i 's/address = "tcp:\/\/localhost:1317"/address = "tcp:\/\/0.0.0.0:1317"/g' "$CONFIG_DIR/app.toml"
sed -i 's/address = "localhost:9090"/address = "0.0.0.0:9090"/g' "$CONFIG_DIR/app.toml"
sed -i 's/minimum-gas-prices = ""/minimum-gas-prices = "0uatone,0uphoton"/g' "$CONFIG_DIR/app.toml"

# config.toml: bind RPC to 0.0.0.0, fast blocks
sed -i 's/laddr = "tcp:\/\/127.0.0.1:26657"/laddr = "tcp:\/\/0.0.0.0:26657"/g' "$CONFIG_DIR/config.toml"
sed -i 's/timeout_commit = "5s"/timeout_commit = "1s"/g' "$CONFIG_DIR/config.toml"
sed -i 's/timeout_propose = "3s"/timeout_propose = "1s"/g' "$CONFIG_DIR/config.toml"

# Allow CORS for queries
sed -i 's/cors_allowed_origins = \[\]/cors_allowed_origins = ["*"]/g' "$CONFIG_DIR/config.toml"

echo "Starting AtomOne..."
exec atomoned start --home /root/.atomone
