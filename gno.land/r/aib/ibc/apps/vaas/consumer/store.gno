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

	// pendingChanges stores accumulated validator updates that have been
	// received via IBC but not yet applied.
	// Key: pubkey string, Value: *ValidatorUpdate
	pendingChanges *avl.Tree

	// providerClientID is the IBC client ID for the provider chain.
	// Set on the first received VSC packet.
	providerClientID string

	// lastValsetUpdateID is the most recently processed valset update ID.
	lastValsetUpdateID uint64

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
		pendingChanges:         avl.NewTree(),
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
// Pending changes
// ---------------------------------------------------------------------------

// getPendingChanges returns the current list of accumulated pending validator
// updates. Returns nil if there are no pending changes.
func getPendingChanges() []ValidatorUpdate {
	if store.pendingChanges.Size() == 0 {
		return nil
	}
	updates := make([]ValidatorUpdate, 0, store.pendingChanges.Size())
	store.pendingChanges.Iterate("", "", func(key string, value interface{}) bool {
		vu := value.(*ValidatorUpdate)
		updates = append(updates, *vu)
		return false
	})
	return updates
}

// setPendingChanges replaces the pending changes with the given list.
func setPendingChanges(updates []ValidatorUpdate) {
	store.pendingChanges = avl.NewTree()
	for i := range updates {
		store.pendingChanges.Set(updates[i].PubKey, &updates[i])
	}
}

// clearPendingChanges removes all pending changes.
func clearPendingChanges() {
	store.pendingChanges = avl.NewTree()
}

// GetPendingChanges returns the current list of accumulated pending validator
// updates. This is the public accessor.
func GetPendingChanges() []ValidatorUpdate {
	return getPendingChanges()
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

// GetLastValsetUpdateID returns the most recently processed valset update ID.
func GetLastValsetUpdateID() uint64 {
	return store.lastValsetUpdateID
}

func setLastValsetUpdateID(id uint64) {
	store.lastValsetUpdateID = id
}

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
// Apply pending changes to cross-chain validators
// ---------------------------------------------------------------------------

// applyValidatorChanges applies a list of validator updates to the current
// cross-chain validator set. For each update:
//   - If the validator exists and the new power is > 0, update its power.
//   - If the validator exists and the new power is 0, remove it.
//   - If the validator does not exist and the power is > 0, add it.
//   - If the validator does not exist and the power is 0, skip it.
//
// Returns the list of updates that were actually applied (excluding skips).
func applyValidatorChanges(changes []ValidatorUpdate) []ValidatorUpdate {
	applied := make([]ValidatorUpdate, 0, len(changes))

	for _, change := range changes {
		_, found := getCCValidator(change.PubKey)

		if found {
			if change.Power < 1 {
				// Remove existing validator
				deleteCCValidator(change.PubKey)
			} else {
				// Update existing validator's power
				setCCValidator(CrossChainValidator{
					PubKey: change.PubKey,
					Power:  change.Power,
				})
			}
			applied = append(applied, change)
		} else if change.Power > 0 {
			// Add new validator
			setCCValidator(CrossChainValidator{
				PubKey: change.PubKey,
				Power:  change.Power,
			})
			applied = append(applied, change)
		}
		// else: update for 0 power on non-existing validator — skip
	}

	return applied
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
