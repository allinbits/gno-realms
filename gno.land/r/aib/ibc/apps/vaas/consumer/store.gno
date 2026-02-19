package consumer

import (
	"crypto/bech32"
	"crypto/sha256"
	"encoding/base64"
	"strconv"

	"gno.land/p/nt/avl"
	"gno.land/p/sys/validators"
	valrealms "gno.land/r/sys/validators/v2"
)

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

// deleteCCValidator removes a cross-chain validator by public key.
func deleteCCValidator(pubKey string) {
	store.validators.Remove(pubKey)
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
// r/sys/validators/v2.
func applyValidatorChanges(changes []ValidatorUpdate) {
	for _, change := range changes {
		_, found := getCCValidator(change.PubKey)

		if found {
			if change.Power <= 0 {
				// Remove existing validator from local store
				deleteCCValidator(change.PubKey)
				// Propagate removal to chain validator set
				propagateValidatorRemoval(change)
			} else {
				// Update existing validator's power in local store
				setCCValidator(CrossChainValidator{
					PubKey: change.PubKey,
					Power:  change.Power,
				})
				// Propagate update to chain validator set
				propagateValidatorUpdate(change)
			}
		} else if change.Power > 0 {
			// Add new validator to local store
			setCCValidator(CrossChainValidator{
				PubKey: change.PubKey,
				Power:  change.Power,
			})
			// Propagate addition to chain validator set
			propagateValidatorAddition(change)
		}
		// else: update for non-positive power on non-existing validator — skip
	}
}

// deriveAddressFromPubKey derives a bech32 address from a public key.
// The public key is in format "<type>:<base64value>".
// Uses SHA256 hash and takes the first 20 bytes, then encodes as bech32.
func deriveAddressFromPubKey(pubKey string) address {
	// Extract base64 part after the colon
	idx := 0
	for i := 0; i < len(pubKey); i++ {
		if pubKey[i] == ':' {
			idx = i + 1
			break
		}
	}
	base64Key := pubKey[idx:]

	// Decode base64
	keyBytes, err := base64.StdEncoding.DecodeString(base64Key)
	if err != nil {
		panic("invalid base64 in pubkey: " + err.Error())
	}

	// Hash with SHA256 and take first 20 bytes (like Tendermint/Tendermint2)
	hash := sha256.Sum256(keyBytes)
	addrBytes := hash[:20]

	// Encode as bech32 with "g" prefix (gno address format)
	// TODO: After https://github.com/gnolang/gno/pull/4873 this should not be hardcoded.
	bechAddr, err := bech32.EncodeFromBase256("g", addrBytes)
	if err != nil {
		panic("failed to encode address as bech32: " + err.Error())
	}

	return address(bechAddr)
}

// encodePubKeyAsBech32 encodes a public key in bech32 format.
// The public key is in format "<type>:<base64value>".
func encodePubKeyAsBech32(pubKey string) string {
	// Extract base64 part after the colon
	idx := 0
	for i := 0; i < len(pubKey); i++ {
		if pubKey[i] == ':' {
			idx = i + 1
			break
		}
	}
	base64Key := pubKey[idx:]

	// Decode base64
	keyBytes, err := base64.StdEncoding.DecodeString(base64Key)
	if err != nil {
		panic("invalid base64 in pubkey: " + err.Error())
	}

	// Encode as bech32 with "pub" prefix
	bechPub, err := bech32.EncodeFromBase256("pub", keyBytes)
	if err != nil {
		panic("failed to encode pubkey as bech32: " + err.Error())
	}

	return bechPub
}

// propagateValidatorAddition adds a validator to the chain validator set.
// This realm must be whitelisted in r/sys/validators/v2 to succeed.
func propagateValidatorAddition(update ValidatorUpdate) {
	addr := deriveAddressFromPubKey(update.PubKey)
	pubKeyBech32 := encodePubKeyAsBech32(update.PubKey)

	// Create validator struct
	val := validators.Validator{
		Address:     addr,
		PubKey:      pubKeyBech32,
		VotingPower: uint64(update.Power),
	}

	valrealms.AddValidator(cross, val)
}

// propagateValidatorRemoval removes a validator from the chain validator set.
func propagateValidatorRemoval(update ValidatorUpdate) {
	addr := deriveAddressFromPubKey(update.PubKey)
	valrealms.RemoveValidator(cross, addr)
}

// propagateValidatorUpdate updates a validator's power in the chain validator set.
// For updates, we use AddValidator which will update the power if the validator exists.
func propagateValidatorUpdate(update ValidatorUpdate) {
	addr := deriveAddressFromPubKey(update.PubKey)
	pubKeyBech32 := encodePubKeyAsBech32(update.PubKey)

	// Create validator struct with updated power
	val := validators.Validator{
		Address:     addr,
		PubKey:      pubKeyBech32,
		VotingPower: uint64(update.Power),
	}

	// Call the validators realm to update the validator
	// AddValidator will update the power if the validator already exists
	valrealms.AddValidator(cross, val)
}
