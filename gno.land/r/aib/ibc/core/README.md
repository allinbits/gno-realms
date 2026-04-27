# r/aib/ibc

Because most of the functions in this realm take complex args, it is required
to call them using `MsgRun` (`maketx run` with the CLI) instead of the more
commonly used `MsgCall`.

Here is an exemple of the command:

```
$ gnokey maketx run -gas-fee 1000000ugnot -gas-wanted 90000000 \
    -broadcast -chainid "dev" -remote "tcp://127.0.0.1:26657" \
    ADDRESS run.gno
```

`run.gno` content depends on the called function, see the following sections
for examples.

## CreateClient

See [`zz_create_client_example_filetest.gno`](./zz_create_client_example_filetest.gno)

Emitted event:
```json
{
  "type": "create_client",
  "attrs": [
    {
      "key": "client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    },
    {
      "key": "consensus_heights",
      "value": "2/2"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## RegisterCounterparty

See [`zz_register_counterparty_example_filetest.gno`](./zz_register_counterparty_example_filetest.gno)

## UpdateClient

See [`zz_update_client_example_filetest.gno`](./zz_update_client_example_filetest.gno)

Emitted event:
```json
{
  "type": "update_client",
  "attrs": [
    {
      "key": "client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    },
    {
      "key": "consensus_heights",
      "value": "2/5"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## SendPacket

See [`zz_send_packet_example_filetest.gno`](./zz_send_packet_example_filetest.gno)

Emitted event:
```json
[
  {
    "type": "send_packet",
    "attrs": [
      {
        "key": "packet_source_client",
        "value": "07-tendermint-1"
      },
      {
        "key": "packet_dest_client",
        "value": "counter-party-id"
      },
      {
        "key": "packet_sequence",
        "value": "1"
      },
      {
        "key": "packet_timeout_timestamp",
        "value": "1234571490"
      },
      {
        "key": "encoded_packet_hex",
        "value": "0801120f30372d74656e6465726d696e742d311a10636f756e7465722d70617274792d696420e2a1d8cc042a3f0a12676e6f2e6c616e645f725f69626361707031120f64657374696e6174696f6e506f72741a02763122106170706c69636174696f6e2f6a736f6e2a027b7d2a3f0a12676e6f2e6c616e645f725f69626361707032120f64657374696e6174696f6e506f72741a02763122106170706c69636174696f6e2f6a736f6e2a027b7d"
      }
    ],
    "pkg_path": "gno.land/r/aib/ibc/core"
  },
]
```

## Acknowledgement

See [`zz_acknowledgement_example_filetest.gno`](./zz_acknowledgement_example_filetest.gno)

Emitted event:
```json
[
  {
    "type": "acknowledge_packet",
    "attrs": [
      {
        "key": "packet_source_client",
        "value": "07-tendermint-1"
      },
      {
        "key": "packet_dest_client",
        "value": "07-tendermint-42"
      },
      {
        "key": "packet_sequence",
        "value": "1"
      },
      {
        "key": "packet_timeout_timestamp",
        "value": "1234571490"
      },
      {
        "key": "encoded_packet_hex",
        "value": "0801120f30372d74656e6465726d696e742d311a1030372d74656e6465726d696e742d343220e2a1d8cc042a300a03617070120f64657374696e6174696f6e506f72741a02763122106170706c69636174696f6e2f6a736f6e2a027b7d"
      }
    ],
    "pkg_path": "gno.land/r/aib/ibc/core"
  }
]
```

## RecoverClient

See [`recover-client.md`](./recover-client.md) for the end-to-end flow and
which parameters can be adjusted during recovery.

Emitted event:
```json
{
  "type": "recover_client",
  "attrs": [
    {
      "key": "subject_client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "substitute_client_id",
      "value": "07-tendermint-2"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```

## UpgradeClient

Upgrades the client to a new client state and consensus state committed by
the counterparty chain at the upgrade path. Used when the counterparty
performs a breaking upgrade — e.g. a `ChainID` or revision-number change,
or a change to security parameters such as `UnbondingPeriod` or
`ProofSpecs` — that `UpdateClient` cannot follow.

Preconditions:
- The client's `UpgradePath` must be set.
- The upgraded client's `LatestHeight` must be greater than the current
  latest height.
- The proofs must verify membership of the upgraded client and consensus
  state at the upgrade path under the current latest consensus root.

On success, the chain-specified fields (`ChainID`, `UnbondingPeriod`,
`LatestHeight`, `ProofSpecs`, `UpgradePath`) are taken from the upgraded
client; the customizable fields (`TrustLevel`, `TrustingPeriod`,
`MaxClockDrift`) are preserved from the current client, with
`TrustingPeriod` scaled proportionally if the unbonding period shrank.

Emitted event:
```json
{
  "type": "upgrade_client",
  "attrs": [
    {
      "key": "client_id",
      "value": "07-tendermint-1"
    },
    {
      "key": "client_type",
      "value": "07-tendermint"
    }
  ],
  "pkg_path": "gno.land/r/aib/ibc/core"
}
```
