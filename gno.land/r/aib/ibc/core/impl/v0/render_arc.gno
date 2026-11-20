package impl

import (
	"gno.land/p/aib/ibc/lightclient/arc/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/onbloc/json/v0"
)

// RenderArcClientState renders the client state of an Arc client. uint64
// values are decimal strings.
func RenderArcClientState(height types.Height, cs *arc.ClientState) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"chain_id":                  RenderUint(cs.ChainID),
		"latest_height":             RenderHeight(height),
		"is_frozen":                 json.BoolNode("", cs.IsFrozen),
		"trusting_period":           RenderUint(cs.TrustingPeriod),
		"max_clock_drift":           RenderUint(cs.MaxClockDrift),
		"trust_level_numerator":     RenderUint(cs.TrustLevel.Numerator),
		"trust_level_denominator":   RenderUint(cs.TrustLevel.Denominator),
		"registry_address":          RenderBytes(cs.RegistryAddress),
		"registry_storage_location": RenderBytes(cs.RegistryStorageLocation),
		"registry_implementation":   RenderBytes(cs.RegistryImplementation),
		"ibc_contract_address":      RenderBytes(cs.IBCContractAddress),
		"ibc_commitment_slot":       RenderBytes(cs.IBCCommitmentSlot),
	})
}

// RenderArcConsensusState renders the consensus state of an Arc client:
// registry_storage_root tells a relayer whether an update must carry the
// validator set's storage nodes (when the registry's root changed).
func RenderArcConsensusState(height types.Height, cs *arc.ConsensusState) *json.Node {
	vals := make([]*json.Node, len(cs.NextValidators.Validators))
	for i, v := range cs.NextValidators.Validators {
		vals[i] = json.ObjectNode("", map[string]*json.Node{
			"address": RenderBytes(v.Address),
			"power":   RenderUint(v.Power),
		})
	}
	return json.ObjectNode("", map[string]*json.Node{
		"height":                RenderHeight(height),
		"timestamp":             json.NumberNode("", float64(cs.Timestamp)),
		"block_hash":            RenderBytes(cs.BlockHash),
		"state_root":            RenderBytes(cs.StateRoot),
		"registry_storage_root": RenderBytes(cs.RegistryStorageRoot),
		"next_validators":       json.ArrayNode("", vals),
		"next_total_power":      RenderUint(cs.NextValidators.TotalPower),
	})
}
