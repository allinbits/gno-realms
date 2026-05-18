package consumer

import (
	"crypto/bech32"
	"crypto/sha256"
	"encoding/base64"
	"strconv"

	"gno.land/p/aib/encoding/proto"
	"gno.land/p/nt/avl/v0"
	validators "gno.land/r/sys/validators/v3"
)

// consumerPkgPath is the canonical package path of this realm.
// It is used to check whether this realm is whitelisted in r/sys/validators/v3
// before attempting to propagate validator set changes to the chain.
const consumerPkgPath = "gno.land/r/aib/ibc/apps/vaas/consumer"

// CrossChainValidator represents a validator that is tracked by the consumer
// chain, as communicated by the provider chain via IBC.
type CrossChainValidator struct {
	// PubKey is the canonical public key of the validator.
	// Format: "<type>:<base64value>" where type is "ed25519" or "secp256k1".
	PubKey string
	// Power is the current voting power of this validator.
	Power int64
}

// consumerStore holds all persistent state for the VAAS consumer app.
type consumerStore struct {
	// validators stores the current cross-chain validator set.
	// Key: pubkey string (canonical format "type:base64"), Value: *CrossChainValidator
	validators *avl.Tree

	// providerClientID is the IBC client ID for the provider chain.
	// Set on the first received VSC packet.
	providerClientID string

	// highestValsetUpdateID is the highest valset update ID that has been
	// processed. Used for out-of-order packet handling: if a packet arrives
	// with a ValsetUpdateId <= highestValsetUpdateID, it is acknowledged
	// but ignored (stale/out-of-order).
	highestValsetUpdateID uint64

	// heightToValsetUpdateID maps block heights to valset update IDs.
	// Key: height as string, Value: uint64
	heightToValsetUpdateID *avl.Tree
}

// Global store instance, initialized in init().
var store consumerStore

func init() {
	store = consumerStore{
		validators:             avl.NewTree(),
		heightToValsetUpdateID: avl.NewTree(),
	}
}

// ---------------------------------------------------------------------------
// Provider client
// ---------------------------------------------------------------------------

// GetProviderClientID returns the provider client ID and whether it has been set.
func GetProviderClientID() (string, bool) {
	if store.providerClientID == "" {
		return "", false
	}
	return store.providerClientID, true
}

func setProviderClientID(clientID string) {
	store.providerClientID = clientID
}

// ---------------------------------------------------------------------------
// Cross-chain validators
// ---------------------------------------------------------------------------

// getCCValidator returns a cross-chain validator by public key.
func getCCValidator(pubKey string) (*CrossChainValidator, bool) {
	v, ok := store.validators.Get(pubKey)
	if !ok {
		return nil, false
	}
	return v.(*CrossChainValidator), true
}

// setCCValidator stores or updates a cross-chain validator.
func setCCValidator(val CrossChainValidator) {
	store.validators.Set(val.PubKey, &val)
}

// GetCCValidator returns a cross-chain validator by public key.
// Returns the validator and true if found, or an empty validator and false if not.
func GetCCValidator(pubKey string) (CrossChainValidator, bool) {
	v, ok := getCCValidator(pubKey)
	if !ok {
		return CrossChainValidator{}, false
	}
	return *v, true
}

// GetAllCCValidators returns all cross-chain validators in the current set.
func GetAllCCValidators() []CrossChainValidator {
	vals := make([]CrossChainValidator, 0, store.validators.Size())
	store.validators.Iterate("", "", func(key string, value interface{}) bool {
		v := value.(*CrossChainValidator)
		vals = append(vals, *v)
		return false
	})
	return vals
}

// GetCCValidatorCount returns the number of active cross-chain validators.
func GetCCValidatorCount() int {
	return store.validators.Size()
}

// GetTotalVotingPower returns the sum of all active cross-chain validators'
// voting power.
func GetTotalVotingPower() int64 {
	var total int64
	store.validators.Iterate("", "", func(key string, value interface{}) bool {
		v := value.(*CrossChainValidator)
		total += v.Power
		return false
	})
	return total
}

// ---------------------------------------------------------------------------
// Valset update ID tracking
// ---------------------------------------------------------------------------

// GetHighestValsetUpdateID returns the highest valset update ID that has been
// processed. Used for out-of-order packet handling.
func GetHighestValsetUpdateID() uint64 {
	return store.highestValsetUpdateID
}

func setHighestValsetUpdateID(id uint64) {
	store.highestValsetUpdateID = id
}

// setHeightValsetUpdateID records the mapping from a block height to the
// valset update ID that was applied at that height.
func setHeightValsetUpdateID(height uint64, valsetUpdateID uint64) {
	store.heightToValsetUpdateID.Set(
		strconv.FormatUint(height, 10),
		valsetUpdateID,
	)
}

// GetHeightValsetUpdateID returns the valset update ID recorded for the given
// block height. Returns 0 if not found.
func GetHeightValsetUpdateID(height uint64) uint64 {
	v, ok := store.heightToValsetUpdateID.Get(strconv.FormatUint(height, 10))
	if !ok {
		return 0
	}
	return v.(uint64)
}

// ---------------------------------------------------------------------------
// Apply validator changes to cross-chain validators
// ---------------------------------------------------------------------------

// applyValidatorChanges applies a list of validator updates to the current
// cross-chain validator set. For each update:
//   - If the validator exists and the new power is > 0, update its power.
//   - If the validator exists and the new power is <= 0, remove it.
//   - If the validator does not exist and the power is > 0, add it.
//   - If the validator does not exist and the power is <= 0, skip it.
//
// This also propagates the changes to the chain's validator set via
// r/sys/validators/v3.
func applyValidatorChanges(changes []ValidatorUpdate) {
	for _, change := range changes {
		_, found := getCCValidator(change.PubKey)

		if found {
			if change.Power <= 0 {
				store.validators.Remove(change.PubKey)
				propagateValidatorRemoval(change)
			} else {
				val := CrossChainValidator{PubKey: change.PubKey, Power: change.Power}
				store.validators.Set(val.PubKey, &val)
				propagateValidatorToChain(change)
			}
		} else if change.Power > 0 {
			val := CrossChainValidator{PubKey: change.PubKey, Power: change.Power}
			store.validators.Set(val.PubKey, &val)
			propagateValidatorToChain(change)
		}
	}
}

// decodePubKeyBytes extracts and decodes the raw key bytes from a public key
// string in "<type>:<base64value>" format.
func decodePubKeyBytes(pubKey string) []byte {
	idx := 0
	for i := 0; i < len(pubKey); i++ {
		if pubKey[i] == ':' {
			idx = i + 1
			break
		}
	}
	keyBytes, err := base64.StdEncoding.DecodeString(pubKey[idx:])
	if err != nil {
		panic("invalid base64 in pubkey: " + err.Error())
	}
	return keyBytes
}

// deriveAddressFromPubKey derives a bech32 address from a public key.
// Uses SHA256 hash and takes the first 20 bytes, then encodes as bech32.
func deriveAddressFromPubKey(pubKey string) address {
	hash := sha256.Sum256(decodePubKeyBytes(pubKey))
	// Encode as bech32 with "g" prefix (gno address format)
	// TODO: After https://github.com/gnolang/gno/pull/4873 this should not be hardcoded.
	bechAddr, err := bech32.EncodeFromBase256("g", hash[:20])
	if err != nil {
		panic("failed to encode address as bech32: " + err.Error())
	}
	return address(bechAddr)
}

// encodePubKeyAsBech32 encodes the public key as a bech32 "gpub" string
// containing a protobuf Any with the correct type URL for the key algorithm.
// This matches the format expected by chain.PubKeyAddress and the valset entries.
func encodePubKeyAsBech32(pubKey string) string {
	keyType := pubKeyType(pubKey)
	rawKey := decodePubKeyBytes(pubKey)

	var typeURL string
	switch keyType {
	case "ed25519":
		typeURL = "/tm.PubKeyEd25519"
	case "secp256k1":
		typeURL = "/tm.PubKeySecp256k1"
	default:
		panic("unsupported key type: " + keyType)
	}

	pkValue := proto.AppendLengthDelimited(nil, 1, rawKey)
	anyBytes := proto.MarshalAny(typeURL, pkValue)

	bechPub, err := bech32.EncodeFromBase256("gpub", anyBytes)
	if err != nil {
		panic("failed to encode pubkey as bech32: " + err.Error())
	}
	return bechPub
}

// pubKeyType extracts the key type from a public key string in
// "<type>:<base64value>" format.
func pubKeyType(pubKey string) string {
	for i := 0; i < len(pubKey); i++ {
		if pubKey[i] == ':' {
			return pubKey[:i]
		}
	}
	panic("invalid pubkey format: missing ':' separator")
}

// propagateValidatorRemoval removes a validator from the chain validator set.
// If the realm is not whitelisted, or if the validator is not present in the
// chain set (e.g. because the local store was set up out-of-band), this is a
// no-op.
func propagateValidatorRemoval(update ValidatorUpdate) {
	if !validators.IsAllowedRealm(consumerPkgPath) {
		return
	}

	addr := deriveAddressFromPubKey(update.PubKey)
	if !validators.IsValidator(addr) {
		// Already absent from the chain validator set — nothing to do.
		return
	}
	validators.RemoveValidator(cross, addr)
}

// propagateValidatorToChain adds or updates a validator in the chain validator set.
func propagateValidatorToChain(update ValidatorUpdate) {
	if !validators.IsAllowedRealm(consumerPkgPath) {
		return
	}

	addr := deriveAddressFromPubKey(update.PubKey)

	if validators.IsValidator(addr) {
		existing := validators.GetValidator(addr)
		if existing.VotingPower == uint64(update.Power) {
			return
		}
	}

	pubKeyBech32 := encodePubKeyAsBech32(update.PubKey)
	validators.AddValidator(cross, validators.ValoperChange{
		OperatorAddress: addr,
		Power:           uint64(update.Power),
	}, pubKeyBech32, addr)
}
