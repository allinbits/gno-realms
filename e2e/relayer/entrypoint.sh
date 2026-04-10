#!/bin/bash

ATOMONE_CHAIN_ID="${ATOMONE_CHAIN_ID:-atomone-e2e-1}"
GNO_CHAIN_ID="${GNO_CHAIN_ID:-dev}"

# Patch gas limits in the gno IBC client (gas refactor branch has higher gas costs)
# Multiply all gas_wanted and gas_fee by 5x
for f in /usr/src/app/dist/clients/gno/IbcClient.cjs /usr/src/app/dist/clients/gno/IbcClient.js; do
    [ -f "$f" ] || continue
    node -e "
      const fs = require('fs');
      let code = fs.readFileSync('$f', 'utf8');
      // Match gas_wanted with BigInt literals (50000000n), new Long(...), or BigInt(...)
      code = code.replace(/gas_wanted:\s*(\d+)n/g,
        (m, val) => 'gas_wanted: ' + (BigInt(val) * 5n) + 'n');
      code = code.replace(/gas_wanted:\s*new\s+(?:Long|long\.default)\((\d+(?:\.\d+)?e\d+|\d+)/g,
        (m, val) => 'gas_wanted: new Long(' + (parseFloat(val) * 5));
      code = code.replace(/gas_wanted:\s*BigInt\((\d+(?:\.\d+)?e\d+|\d+)/g,
        (m, val) => 'gas_wanted: BigInt(' + (parseFloat(val) * 5));
      // Match gas_fee static strings
      code = code.replace(/gas_fee:\s*\"(\d+)ugnot\"/g,
        (m, fee) => 'gas_fee: \"' + (parseInt(fee) * 5) + 'ugnot\"');
      // Match gas_fee Math.floor expressions
      code = code.replace(/Math\.floor\((\d+(?:\.\d+)?e\d+|\d+)\s*\*\s*(packets|acks)\.length\s*\/\s*1e3\)/g,
        (m, val, varName) => 'Math.floor(' + (parseFloat(val) * 5) + ' * ' + varName + '.length / 1e3)');
      fs.writeFileSync('$f', code);
    "
done

echo "Configuring relayer..."

/bin/with_keyring bash -eu -c "
    echo 'Adding mnemonics...'
    ibc-v2-ts-relayer add-mnemonic -c $ATOMONE_CHAIN_ID --mnemonic \"$RELAYER_MNEMONIC\"
    ibc-v2-ts-relayer add-mnemonic -c $GNO_CHAIN_ID --mnemonic \"$RELAYER_MNEMONIC\"

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
