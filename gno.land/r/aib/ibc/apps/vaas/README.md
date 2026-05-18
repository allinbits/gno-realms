# VAAS consumer

Validator As A Service (VAAS) consumer app for IBC v2 on Gno. The consumer
receives validator set change (VSC) packets from a provider chain and applies
them to the local cross-chain validator set.

It follows the same model as the Cosmos SDK `ccv/consumer` module, adapted for
IBC v2's payload-based packets.

## How it works

The consumer never sends packets. It only receives them.

When a VSC packet arrives from the provider, the consumer:

1. Validates the payload (ports, version, encoding, packet data)
2. Records the provider client ID on the first packet, then enforces it on
   subsequent packets
3. Applies validator updates (add, update power, remove)
4. Propagates changes to the chain's validator set via `r/sys/validators/v3`
5. Stores the valset update ID for out-of-order packet handling

## Registration

The app registers itself in `init()` on port `vaasconsumer`:

```gno
core.RegisterApp(cross, "vaasconsumer", &App{})
```

Packets from the provider must arrive on port `vaasprovider`.

| Constant         | Value              |
| ---------------- | ------------------ |
| Port ID          | `vaasconsumer`     |
| Provider Port ID | `vaasprovider`     |
| Version          | `vaas-v1`          |
| Encoding         | `application/x-protobuf` |

## Packet format

The provider sends `ValidatorSetChangePacketData` as protobuf:

```protobuf
message ValidatorSetChangePacketData {
  repeated ValidatorUpdate validator_updates = 1;
  uint64 valset_update_id = 2;
}

message ValidatorUpdate {
  PublicKey pub_key = 1;
  int64 power = 2;
}

message PublicKey {
  oneof sum {
    bytes ed25519   = 1;
    bytes secp256k1 = 2;
  }
}
```

- `pub_key` contains raw key bytes under field 1 (ed25519) or field 2 (secp256k1)
- `power` is an int64 varint. Omitted (0) means validator removal.
- `valset_update_id` is a strictly positive, monotonically increasing counter

Public keys are stored internally as `<type>:<base64>` (e.g.
`ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=`).

## Out-of-order packets

Packets can arrive out of order because of relayer behavior. The consumer tracks
`highestValsetUpdateID` to handle this:

- Packets with `ValsetUpdateId <= highestValsetUpdateID` get a success ack but
  are not applied (stale).
- Only packets with `ValsetUpdateId > highestValsetUpdateID` are processed.

## Provider client binding

The first received packet determines the provider client ID. After that, packets
from any other client are rejected. This stops rogue clients from injecting
validator updates.

## Chain validator propagation

Validator changes go through `r/sys/validators/v3` to reach the chain's
consensus validator set. The consumer realm needs to be whitelisted by that
package (`validators.IsAllowedRealm`). Without whitelisting, changes are tracked
internally but never reach consensus.

Key derivation: SHA-256 of the raw public key bytes, bech32-encoded with the `g`
prefix for operator addresses, and protobuf `Any`-wrapped with `gpub` prefix for
public key addresses.

## Query endpoints

All endpoints return JSON, accessible via gnoweb or
`gnokey query vm/qrender`.

| Path                       | Description                                       |
| -------------------------- | ------------------------------------------------- |
| `config`                   | Realm configuration (port IDs, version, encoding) |
| `provider_client_id`       | Provider client ID (empty if not established)     |
| `highest_valset_update_id` | Highest processed valset update ID                |
| `validator_count`          | Number of active cross-chain validators           |
| `total_voting_power`       | Sum of all validators' voting power               |
| `validators`               | Full list of validators with pubkey and power     |

Example:

```
gnokey query vm/qrender -data "gno.land/r/aib/ibc/apps/vaas/consumer:validators"
```

```json
{ "validators": [{ "pub_key": "ed25519:aPFcGO...", "power": "100" }] }
```

Calling `Render` with no path returns a human-readable Markdown summary.

## Helper functions

```gno
val, ok := consumer.GetCCValidator("ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEjjx2jKQ=")
vals := consumer.GetAllCCValidators()
count := consumer.GetCCValidatorCount()
power := consumer.GetTotalVotingPower()
clientID, ok := consumer.GetProviderClientID()
highest := consumer.GetHighestValsetUpdateID()
vuID := consumer.GetHeightValsetUpdateID(height)
pk := consumer.MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEjjx2jKQ=")
```

## Events

### `vaas_packet`

Emitted on successful `OnRecvPacket`.

| Attribute          | Description                               |
| ------------------ | ----------------------------------------- |
| `valset_update_id` | The VSC packet's valset update ID         |
| `num_updates`      | Number of validator updates in the packet |
| `success`          | `"true"`                                  |
| `source_client`    | Source client ID                          |

### `channel_established`

Emitted on the first received packet from the provider.

| Attribute   | Description        |
| ----------- | ------------------ |
| `module`    | `vaasconsumer`     |
| `client_id` | Provider client ID |

### `timeout`

Emitted on `OnTimeoutPacket`.

| Attribute            | Description           |
| -------------------- | --------------------- |
| `module`             | `vaasconsumer`        |
| `source_client`      | Source client ID      |
| `destination_client` | Destination client ID |
| `sequence`           | Packet sequence       |

### `vaas_acknowledgement`

Emitted on `OnAcknowledgementPacket`.

| Attribute            | Description           |
| -------------------- | --------------------- |
| `module`             | `vaasconsumer`        |
| `source_client`      | Source client ID      |
| `destination_client` | Destination client ID |
| `sequence`           | Packet sequence       |
