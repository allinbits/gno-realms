package consumer

import (
	"strconv"

	"gno.land/p/nt/avl"
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
func applyValidatorChanges(changes []ValidatorUpdate) {
	for _, change := range changes {
		_, found := getCCValidator(change.PubKey)

		if found {
			if change.Power <= 0 {
				// Remove existing validator
				deleteCCValidator(change.PubKey)
			} else {
				// Update existing validator's power
				setCCValidator(CrossChainValidator{
					PubKey: change.PubKey,
					Power:  change.Power,
				})
			}
		} else if change.Power > 0 {
			// Add new validator
			setCCValidator(CrossChainValidator{
				PubKey: change.PubKey,
				Power:  change.Power,
			})
		}
		// else: update for non-positive power on non-existing validator — skip
	}
}

// serializeValidatorSet returns the current validator set as a slice of
// strings in the format "pubkey:power". This format is compatible with the
// params keeper approach described in gnolang/gno#3999.
func serializeValidatorSet() []string {
	vals := GetAllCCValidators()
	entries := make([]string, len(vals))
	for i, v := range vals {
		entries[i] = v.PubKey + ":" + strconv.FormatInt(v.Power, 10)
	}
	return entries
}
