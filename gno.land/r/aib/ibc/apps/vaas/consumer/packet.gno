package consumer

import (
	"encoding/base64"
	"strconv"

	"gno.land/p/nt/ufmt"
	"gno.land/p/onbloc/json"
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
// Expected JSON format:
//
//	{
//	  "validator_updates": [
//	    {"pub_key": {"ed25519": "<base64>"}, "power": "<int64>"},
//	    ...
//	  ],
//	  "valset_update_id": "<uint64>"
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

// MarshalJSON returns the JSON encoding of the packet data in the format
// expected by the provider.
//
// Format:
//
//	{
//	  "validator_updates": [
//	    {"pub_key": {"ed25519": "<base64>"}, "power": "<int64>"},
//	    ...
//	  ],
//	  "valset_update_id": "<uint64>"
//	}
func (vsc ValidatorSetChangePacketData) MarshalJSON() []byte {
	updates := make([]*json.Node, len(vsc.ValidatorUpdates))
	for i, vu := range vsc.ValidatorUpdates {
		keyType := vu.PubKeyType()
		keyBase64 := vu.PubKeyBase64()

		pubKeyNode := json.ObjectNode("", map[string]*json.Node{
			keyType: json.StringNode("", keyBase64),
		})

		updateFields := map[string]*json.Node{
			"pub_key": pubKeyNode,
		}

		// Omit power if 0 (matches provider behavior)
		if vu.Power != 0 {
			updateFields["power"] = json.StringNode("", strconv.FormatInt(vu.Power, 10))
		}

		updates[i] = json.ObjectNode("", updateFields)
	}

	node := json.ObjectNode("", map[string]*json.Node{
		"validator_updates": json.ArrayNode("", updates),
		"valset_update_id":  json.StringNode("", strconv.FormatUint(vsc.ValsetUpdateId, 10)),
	})

	bz, _ := json.Marshal(node)
	return bz
}

// UnmarshalValidatorSetChangePacketData decodes JSON bytes into a
// ValidatorSetChangePacketData.
//
// Handles:
//   - pub_key as nested object: {"ed25519": "<base64>"} or {"secp256k1": "<base64>"}
//   - power as string ("100") or number (100), or missing (defaults to 0)
//   - valset_update_id as string ("1") or number (1)
func UnmarshalValidatorSetChangePacketData(bz []byte) (ValidatorSetChangePacketData, error) {
	var vsc ValidatorSetChangePacketData

	root, err := json.Unmarshal(bz)
	if err != nil {
		return vsc, ufmt.Errorf("failed to unmarshal VSC packet data: %v", err)
	}

	// Parse valset_update_id (string or number)
	vidNode, err := root.GetKey("valset_update_id")
	if err != nil {
		return vsc, ufmt.Errorf("missing valset_update_id: %v", err)
	}
	vid, err := parseUint64Node(vidNode)
	if err != nil {
		return vsc, ufmt.Errorf("invalid valset_update_id: %v", err)
	}
	vsc.ValsetUpdateId = vid

	// Parse validator_updates
	updatesNode, err := root.GetKey("validator_updates")
	if err != nil {
		return vsc, ufmt.Errorf("missing validator_updates: %v", err)
	}

	updates, err := updatesNode.GetArray()
	if err != nil {
		return vsc, ufmt.Errorf("invalid validator_updates: %v", err)
	}

	vsc.ValidatorUpdates = make([]ValidatorUpdate, len(updates))
	for i, uNode := range updates {
		pkNode, err := uNode.GetKey("pub_key")
		if err != nil {
			return vsc, ufmt.Errorf("missing pub_key in update #%d: %v", i, err)
		}

		pubKey, err := parsePubKeyNode(pkNode)
		if err != nil {
			return vsc, ufmt.Errorf("invalid pub_key in update #%d: %v", i, err)
		}

		// Parse power: may be string, number, or missing (default 0).
		// The provider omits power when it is 0.
		var power int64
		pwNode, pwErr := uNode.GetKey("power")
		if pwErr == nil {
			power, err = parseInt64Node(pwNode)
			if err != nil {
				return vsc, ufmt.Errorf("invalid power in update #%d: %v", i, err)
			}
		}
		// else: power missing => default 0 (validator removal)

		vsc.ValidatorUpdates[i] = ValidatorUpdate{
			PubKey: pubKey,
			Power:  power,
		}
	}

	return vsc, nil
}

// parsePubKeyNode parses a pub_key JSON node, supporting:
// - Nested object format (from provider): {"ed25519": "<base64>"} or {"secp256k1": "<base64>"}
// - Simple string format (legacy/testing): "ed25519:<base64>" or just a plain key string
//
// Returns the canonical string form: "ed25519:<base64>" or "secp256k1:<base64>".
func parsePubKeyNode(node *json.Node) (string, error) {
	// Try as string first (legacy/testing format)
	if s, err := node.GetString(); err == nil {
		// If it already contains ":", assume canonical format
		for i := 0; i < len(s); i++ {
			if s[i] == ':' {
				return s, nil
			}
		}
		// Plain string without ":" — unsupported bare key format
		// Still return it for backward compatibility
		return s, nil
	}

	// Try as object (protobuf JSON format from provider)
	// The object has exactly one key which is the key type
	for _, keyType := range []string{"ed25519", "secp256k1"} {
		valNode, err := node.GetKey(keyType)
		if err != nil {
			continue
		}
		b64, err := valNode.GetString()
		if err != nil {
			return "", ufmt.Errorf("pub_key.%s must be a base64 string", keyType)
		}
		// Validate that it's valid base64
		if _, err := base64.StdEncoding.DecodeString(b64); err != nil {
			return "", ufmt.Errorf("pub_key.%s is not valid base64: %v", keyType, err)
		}
		return keyType + ":" + b64, nil
	}

	return "", ufmt.Errorf("pub_key must be an object with 'ed25519' or 'secp256k1' key")
}

// parseUint64Node parses a JSON node as uint64, supporting both string and number formats.
func parseUint64Node(node *json.Node) (uint64, error) {
	// Try as string first
	if s, err := node.GetString(); err == nil {
		v, err := strconv.ParseUint(s, 10, 64)
		if err != nil {
			return 0, ufmt.Errorf("cannot parse %q as uint64: %v", s, err)
		}
		return v, nil
	}
	// Try as number
	if n, err := node.GetNumeric(); err == nil {
		// n is a float64, convert carefully
		if n < 0 {
			return 0, ufmt.Errorf("negative value %v for uint64", n)
		}
		return uint64(n), nil
	}
	return 0, ufmt.Errorf("value is neither string nor number")
}

// parseInt64Node parses a JSON node as int64, supporting both string and number formats.
func parseInt64Node(node *json.Node) (int64, error) {
	// Try as string first
	if s, err := node.GetString(); err == nil {
		v, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return 0, ufmt.Errorf("cannot parse %q as int64: %v", s, err)
		}
		return v, nil
	}
	// Try as number
	if n, err := node.GetNumeric(); err == nil {
		return int64(n), nil
	}
	return 0, ufmt.Errorf("value is neither string nor number")
}

// MakePubKey creates a canonical pubkey string from type and base64 value.
// This is a helper for tests and internal use.
func MakePubKey(keyType, base64Value string) string {
	return keyType + ":" + base64Value
}
