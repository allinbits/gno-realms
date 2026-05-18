package consumer

import (
	"encoding/base64"
	"encoding/binary"

	"gno.land/p/aib/encoding/proto"
	"gno.land/p/nt/ufmt/v0"
)

// ValidatorUpdate represents a single validator update from the provider chain.
type ValidatorUpdate struct {
	// PubKey is a canonical string representation of the validator's public key.
	// Format: "<type>:<base64value>" where type is "ed25519" or "secp256k1".
	PubKey string
	// Power is the new voting power of the validator. A power of 0 indicates
	// the validator should be removed from the active set.
	Power int64
}

// PubKeyType extracts the key type from the canonical PubKey string.
// Returns "ed25519" or "secp256k1".
func (vu ValidatorUpdate) PubKeyType() string {
	for i := 0; i < len(vu.PubKey); i++ {
		if vu.PubKey[i] == ':' {
			return vu.PubKey[:i]
		}
	}
	return ""
}

// PubKeyBase64 extracts the base64-encoded key bytes from the canonical PubKey string.
func (vu ValidatorUpdate) PubKeyBase64() string {
	for i := 0; i < len(vu.PubKey); i++ {
		if vu.PubKey[i] == ':' {
			return vu.PubKey[i+1:]
		}
	}
	return ""
}

// ValidatorSetChangePacketData is the IBC packet data sent by the provider
// chain to communicate validator set changes to the consumer chain.
//
// Protobuf wire format:
//
//	message ValidatorSetChangePacketData {
//	  repeated ValidatorUpdate validator_updates = 1;
//	  uint64 valset_update_id = 2;
//	}
//	message ValidatorUpdate {
//	  PublicKey pub_key = 1;
//	  int64 power = 2;
//	}
//	message PublicKey {
//	  oneof sum {
//	    bytes ed25519   = 1;
//	    bytes secp256k1 = 2;
//	  }
//	}
//
// Note: zero-value fields may be omitted (e.g. power=0 may be absent).
type ValidatorSetChangePacketData struct {
	// ValidatorUpdates is the list of validator updates to apply.
	// An empty (but non-nil) list is valid and indicates no changes to voting
	// power, but serves as a heartbeat or valset update ID advancement.
	ValidatorUpdates []ValidatorUpdate
	// ValsetUpdateId is a strictly positive, monotonically increasing
	// identifier for this validator set change.
	ValsetUpdateId uint64
}

// Validate performs basic validation of the packet data.
func (vsc ValidatorSetChangePacketData) Validate() error {
	if vsc.ValidatorUpdates == nil {
		return errNilValidatorUpdates
	}
	if vsc.ValsetUpdateId == 0 {
		return errZeroValsetUpdateId
	}
	for _, vu := range vsc.ValidatorUpdates {
		if vu.PubKey == "" {
			return errEmptyPubKey
		}
		// Validate canonical format: "type:base64"
		if vu.PubKeyType() == "" || vu.PubKeyBase64() == "" {
			return errInvalidPubKey
		}
		keyType := vu.PubKeyType()
		if keyType != "ed25519" && keyType != "secp256k1" {
			return errInvalidPubKey
		}
		if vu.Power < 0 {
			return errNegativePower
		}
	}
	return nil
}

// ProtoMarshal returns the protobuf encoding of the packet data.
//
//	message ValidatorSetChangePacketData {
//	  repeated ValidatorUpdate validator_updates = 1;
//	  uint64 valset_update_id = 2;
//	}
//
//	message ValidatorUpdate {
//	  PublicKey pub_key = 1;
//	  int64 power = 2;
//	}
//
//	message PublicKey {
//	  oneof sum {
//	    bytes ed25519   = 1;
//	    bytes secp256k1 = 2;
//	  }
//	}
func (vsc ValidatorSetChangePacketData) ProtoMarshal() []byte {
	var buf []byte

	// Field 1: validator_updates (repeated, length-delimited)
	for _, vu := range vsc.ValidatorUpdates {
		updateBz := marshalValidatorUpdate(vu)
		buf = proto.AppendLengthDelimited(buf, 1, updateBz)
	}

	// Field 2: valset_update_id (varint)
	buf = proto.AppendVarint(buf, 2, vsc.ValsetUpdateId)

	return buf
}

// marshalValidatorUpdate encodes a single ValidatorUpdate into protobuf bytes.
func marshalValidatorUpdate(vu ValidatorUpdate) []byte {
	var buf []byte

	// Field 1: pub_key (embedded message PublicKey)
	pubKeyBz := marshalPublicKey(vu.PubKeyType(), vu.PubKeyBase64())
	buf = proto.AppendAlwaysLengthDelimited(buf, 1, pubKeyBz)

	// Field 2: power (varint, int64 zigzag encoded)
	powerU64 := uint64(vu.Power)
	if powerU64 != 0 {
		buf = proto.AppendTag(buf, 2, proto.VARINT)
		buf = binary.AppendUvarint(buf, powerU64)
	}

	return buf
}

// marshalPublicKey encodes a public key into protobuf bytes.
// fieldNum 1 = ed25519, fieldNum 2 = secp256k1.
func marshalPublicKey(keyType, base64Value string) []byte {
	keyBytes, _ := base64.StdEncoding.DecodeString(base64Value)

	switch keyType {
	case "ed25519":
		var buf []byte
		return proto.AppendLengthDelimited(buf, 1, keyBytes)
	case "secp256k1":
		var buf []byte
		return proto.AppendLengthDelimited(buf, 2, keyBytes)
	default:
		return nil
	}
}

// ProtoUnmarshalValidatorSetChangePacketData decodes protobuf bytes into a
// ValidatorSetChangePacketData.
func ProtoUnmarshalValidatorSetChangePacketData(bz []byte) (ValidatorSetChangePacketData, error) {
	var vsc ValidatorSetChangePacketData
	var pos int

	for pos < len(bz) {
		key, newPos, err := proto.DecodeVarint(bz, pos)
		if err != nil {
			return vsc, ufmt.Errorf("error reading field tag: %v", err)
		}
		pos = newPos

		fieldNum := key >> 3
		wireType := key & 0x07

		switch fieldNum {
		case 1: // validator_updates (length-delimited)
			if wireType != 2 {
				return vsc, ufmt.Errorf("unexpected wire type %d for field %d", wireType, fieldNum)
			}
			updateBz, newPos, err := proto.DecodeString(bz, pos)
			if err != nil {
				return vsc, ufmt.Errorf("error reading validator_update: %v", err)
			}
			pos = newPos

			vu, err := unmarshalValidatorUpdate([]byte(updateBz))
			if err != nil {
				return vsc, err
			}
			vsc.ValidatorUpdates = append(vsc.ValidatorUpdates, vu)

		case 2: // valset_update_id (varint)
			if wireType != 0 {
				return vsc, ufmt.Errorf("unexpected wire type %d for field %d", wireType, fieldNum)
			}
			val, newPos, err := proto.DecodeVarint(bz, pos)
			if err != nil {
				return vsc, ufmt.Errorf("error reading valset_update_id: %v", err)
			}
			pos = newPos
			vsc.ValsetUpdateId = val

		default:
			// Skip unknown fields
			pos, err = skipField(bz, pos, wireType)
			if err != nil {
				return vsc, err
			}
		}
	}

	// Ensure ValidatorUpdates is non-nil (empty slice, not nil) when there are no updates
	// so that Validate() doesn't fail on nil.
	if vsc.ValidatorUpdates == nil {
		vsc.ValidatorUpdates = []ValidatorUpdate{}
	}

	return vsc, nil
}

// unmarshalValidatorUpdate decodes a single ValidatorUpdate from protobuf bytes.
func unmarshalValidatorUpdate(bz []byte) (ValidatorUpdate, error) {
	var vu ValidatorUpdate
	var pos int

	for pos < len(bz) {
		key, newPos, err := proto.DecodeVarint(bz, pos)
		if err != nil {
			return vu, ufmt.Errorf("error reading field tag: %v", err)
		}
		pos = newPos

		fieldNum := key >> 3
		wireType := key & 0x07

		switch fieldNum {
		case 1: // pub_key (embedded message)
			if wireType != 2 {
				return vu, ufmt.Errorf("unexpected wire type %d for pub_key", wireType)
			}
			pubKeyBz, newPos, err := proto.DecodeString(bz, pos)
			if err != nil {
				return vu, ufmt.Errorf("error reading pub_key: %v", err)
			}
			pos = newPos

			keyType, keyBytes, err := unmarshalPublicKey([]byte(pubKeyBz))
			if err != nil {
				return vu, err
			}
			vu.PubKey = keyType + ":" + base64.StdEncoding.EncodeToString(keyBytes)

		case 2: // power (varint)
			if wireType != 0 {
				return vu, ufmt.Errorf("unexpected wire type %d for power", wireType)
			}
			val, newPos, err := proto.DecodeVarint(bz, pos)
			if err != nil {
				return vu, ufmt.Errorf("error reading power: %v", err)
			}
			pos = newPos
			vu.Power = int64(val)

		default:
			pos, err = skipField(bz, pos, wireType)
			if err != nil {
				return vu, err
			}
		}
	}

	return vu, nil
}

// unmarshalPublicKey decodes a PublicKey message, returning the key type and raw bytes.
func unmarshalPublicKey(bz []byte) (string, []byte, error) {
	var pos int

	for pos < len(bz) {
		key, newPos, err := proto.DecodeVarint(bz, pos)
		if err != nil {
			return "", nil, ufmt.Errorf("error reading public key field tag: %v", err)
		}
		pos = newPos

		fieldNum := key >> 3
		wireType := key & 0x07

		if wireType != 2 {
			return "", nil, ufmt.Errorf("unexpected wire type %d for public key field %d", wireType, fieldNum)
		}

		valueStr, newPos, err := proto.DecodeString(bz, pos)
		if err != nil {
			return "", nil, ufmt.Errorf("error reading public key value: %v", err)
		}
		pos = newPos
		valueBytes := []byte(valueStr)

		switch fieldNum {
		case 1:
			return "ed25519", valueBytes, nil
		case 2:
			return "secp256k1", valueBytes, nil
		default:
			return "", nil, ufmt.Errorf("unknown public key field %d", fieldNum)
		}
	}

	return "", nil, ufmt.Errorf("empty public key message")
}

// skipField advances past an unknown protobuf field.
func skipField(bz []byte, pos int, wireType uint64) (int, error) {
	switch wireType {
	case 0: // varint
		_, newPos, err := proto.DecodeVarint(bz, pos)
		if err != nil {
			return pos, err
		}
		return newPos, nil
	case 1: // 64-bit
		if pos+8 > len(bz) {
			return pos, ufmt.Errorf("buffer underflow while skipping fixed64")
		}
		return pos + 8, nil
	case 2: // length-delimited
		length, newPos, err := proto.DecodeVarint(bz, pos)
		if err != nil {
			return pos, err
		}
		end := newPos + int(length)
		if end > len(bz) {
			return newPos, ufmt.Errorf("buffer underflow while skipping length-delimited field")
		}
		return end, nil
	case 5: // 32-bit
		if pos+4 > len(bz) {
			return pos, ufmt.Errorf("buffer underflow while skipping fixed32")
		}
		return pos + 4, nil
	default:
		return pos, ufmt.Errorf("unknown wire type %d", wireType)
	}
}

// UnmarshalValidatorSetChangePacketData decodes protobuf bytes into a
// ValidatorSetChangePacketData.
func UnmarshalValidatorSetChangePacketData(bz []byte) (ValidatorSetChangePacketData, error) {
	vsc, err := ProtoUnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		return vsc, ufmt.Errorf("failed to unmarshal VSC packet data: %v", err)
	}

	return vsc, nil
}

// MakePubKey creates a canonical pubkey string from type and base64 value.
func MakePubKey(keyType, base64Value string) string {
	return keyType + ":" + base64Value
}
