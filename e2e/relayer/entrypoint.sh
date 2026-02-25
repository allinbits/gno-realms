#!/bin/bash
set -eu

ATOMONE_CHAIN_ID="${ATOMONE_CHAIN_ID:-atomone-e2e-1}"
GNO_CHAIN_ID="${GNO_CHAIN_ID:-dev}"

echo "Configuring relayer..."

/bin/with_keyring bash -c "
    echo 'Adding mnemonics...'
    ibc-v2-ts-relayer add-mnemonic -c $ATOMONE_CHAIN_ID -m \"$TEST_MNEMONIC\"
    ibc-v2-ts-relayer add-mnemonic -c $GNO_CHAIN_ID -m \"$TEST_MNEMONIC\"

    echo 'Adding gas prices...'
    ibc-v2-ts-relayer add-gas-price -c $ATOMONE_CHAIN_ID 0.025uphoton
    ibc-v2-ts-relayer add-gas-price -c $GNO_CHAIN_ID 0.025ugnot

    echo 'Adding relay path...'
    ibc-v2-ts-relayer add-path \
        -s $ATOMONE_CHAIN_ID -d $GNO_CHAIN_ID \
        --surl http://atomone:26657 \
        --durl http://gno:26657 \
        --dquery http://tx-indexer:8546/graphql/query \
        --st cosmos --dt gno \
        --ibcv 2

    echo 'Starting relayer...'
    exec \"\$@\"
" -- "$@"
