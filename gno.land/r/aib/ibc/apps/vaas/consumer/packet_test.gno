package consumer

import (
	"testing"

	"gno.land/p/nt/avl"
)

func TestValidatorSetChangePacketData_Validate(t *testing.T) {
	tests := []struct {
		name    string
		vsc     ValidatorSetChangePacketData
		wantErr bool
	}{
		{
			name: "valid packet data with ed25519 key",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 100},
				},
				ValsetUpdateId: 1,
			},
			wantErr: false,
		},
		{
			name: "valid with secp256k1 key",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: MakePubKey("secp256k1", "A7x3FJxIMWJM1xymAKRHLiPMqxR0NQKX2gjHMYNKHZk="), Power: 50},
				},
				ValsetUpdateId: 1,
			},
			wantErr: false,
		},
		{
			name: "valid with empty updates list",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{},
				ValsetUpdateId:   1,
			},
			wantErr: false,
		},
		{
			name: "nil validator updates",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: nil,
				ValsetUpdateId:   1,
			},
			wantErr: true,
		},
		{
			name: "zero valset update id",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 100},
				},
				ValsetUpdateId: 0,
			},
			wantErr: true,
		},
		{
			name: "empty pubkey",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: "", Power: 100},
				},
				ValsetUpdateId: 1,
			},
			wantErr: true,
		},
		{
			name: "invalid pubkey format - no colon separator",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: "justaplainstring", Power: 100},
				},
				ValsetUpdateId: 1,
			},
			wantErr: true,
		},
		{
			name: "invalid pubkey format - bad key type",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: "rsa:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=", Power: 100},
				},
				ValsetUpdateId: 1,
			},
			wantErr: true,
		},
		{
			name: "valid with multiple updates",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100},
					{PubKey: MakePubKey("ed25519", "BBBB"), Power: 0},
					{PubKey: MakePubKey("ed25519", "CCCC"), Power: 50},
				},
				ValsetUpdateId: 42,
			},
			wantErr: false,
		},
		{
			name: "valid with zero power (validator removal)",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: MakePubKey("ed25519", "AAAA"), Power: 0},
				},
				ValsetUpdateId: 1,
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.vsc.Validate()
			if tt.wantErr && err == nil {
				t.Error("expected error, got nil")
			}
			if !tt.wantErr && err != nil {
				t.Errorf("unexpected error: %v", err)
			}
		})
	}
}

func TestPubKeyTypeAndBase64(t *testing.T) {
	vu := ValidatorUpdate{
		PubKey: MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="),
		Power:  100,
	}

	if vu.PubKeyType() != "ed25519" {
		t.Errorf("expected PubKeyType 'ed25519', got %q", vu.PubKeyType())
	}
	if vu.PubKeyBase64() != "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=" {
		t.Errorf("expected PubKeyBase64 'aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=', got %q", vu.PubKeyBase64())
	}

	vu2 := ValidatorUpdate{
		PubKey: MakePubKey("secp256k1", "AAAA"),
		Power:  50,
	}
	if vu2.PubKeyType() != "secp256k1" {
		t.Errorf("expected PubKeyType 'secp256k1', got %q", vu2.PubKeyType())
	}
	if vu2.PubKeyBase64() != "AAAA" {
		t.Errorf("expected PubKeyBase64 'AAAA', got %q", vu2.PubKeyBase64())
	}
}

func TestMarshalUnmarshalRoundTrip(t *testing.T) {
	original := ValidatorSetChangePacketData{
		ValidatorUpdates: []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 100},
			{PubKey: MakePubKey("ed25519", "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 0},
			{PubKey: MakePubKey("secp256k1", "A7x3FJxIMWJM1xymAKRHLiPMqxR0NQKX2gjHMYNKHZk="), Power: 50},
		},
		ValsetUpdateId: 7,
	}

	bz := original.MarshalJSON()
	if len(bz) == 0 {
		t.Fatal("MarshalJSON returned empty bytes")
	}

	decoded, err := UnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if decoded.ValsetUpdateId != original.ValsetUpdateId {
		t.Errorf("ValsetUpdateId mismatch: got %d, want %d", decoded.ValsetUpdateId, original.ValsetUpdateId)
	}

	if len(decoded.ValidatorUpdates) != len(original.ValidatorUpdates) {
		t.Fatalf("ValidatorUpdates length mismatch: got %d, want %d",
			len(decoded.ValidatorUpdates), len(original.ValidatorUpdates))
	}

	for i, vu := range decoded.ValidatorUpdates {
		if vu.PubKey != original.ValidatorUpdates[i].PubKey {
			t.Errorf("update #%d PubKey mismatch: got %s, want %s",
				i, vu.PubKey, original.ValidatorUpdates[i].PubKey)
		}
		if vu.Power != original.ValidatorUpdates[i].Power {
			t.Errorf("update #%d Power mismatch: got %d, want %d",
				i, vu.Power, original.ValidatorUpdates[i].Power)
		}
	}
}

func TestMarshalUnmarshalEmptyUpdates(t *testing.T) {
	original := ValidatorSetChangePacketData{
		ValidatorUpdates: []ValidatorUpdate{},
		ValsetUpdateId:   1,
	}

	bz := original.MarshalJSON()
	decoded, err := UnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if decoded.ValsetUpdateId != 1 {
		t.Errorf("ValsetUpdateId mismatch: got %d, want 1", decoded.ValsetUpdateId)
	}
	if len(decoded.ValidatorUpdates) != 0 {
		t.Errorf("expected empty ValidatorUpdates, got %d", len(decoded.ValidatorUpdates))
	}
}

// TestUnmarshalProviderFormat tests parsing JSON in the exact format that the
// provider sends over IBC (protobuf JSON with nested pub_key objects).
func TestUnmarshalProviderFormat(t *testing.T) {
	// Protobuf JSON format with nested pub_key objects and string values
	input := `{"validator_updates":[{"pub_key":{"ed25519":"aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="},"power":"100"},{"pub_key":{"ed25519":"bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="},"power":"50"}],"valset_update_id":"1"}`

	vsc, err := UnmarshalValidatorSetChangePacketData([]byte(input))
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if vsc.ValsetUpdateId != 1 {
		t.Errorf("ValsetUpdateId: got %d, want 1", vsc.ValsetUpdateId)
	}
	if len(vsc.ValidatorUpdates) != 2 {
		t.Fatalf("expected 2 updates, got %d", len(vsc.ValidatorUpdates))
	}

	// Check first validator
	if vsc.ValidatorUpdates[0].PubKey != "ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=" {
		t.Errorf("update 0 PubKey: got %q", vsc.ValidatorUpdates[0].PubKey)
	}
	if vsc.ValidatorUpdates[0].Power != 100 {
		t.Errorf("update 0 Power: got %d, want 100", vsc.ValidatorUpdates[0].Power)
	}

	// Check second validator
	if vsc.ValidatorUpdates[1].PubKey != "ed25519:bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=" {
		t.Errorf("update 1 PubKey: got %q", vsc.ValidatorUpdates[1].PubKey)
	}
	if vsc.ValidatorUpdates[1].Power != 50 {
		t.Errorf("update 1 Power: got %d, want 50", vsc.ValidatorUpdates[1].Power)
	}
}

// TestUnmarshalProviderFormatPowerAsNumber tests that power as a JSON number
// (not string) is also accepted, since some JSON encoders emit int64 as numbers.
func TestUnmarshalProviderFormatPowerAsNumber(t *testing.T) {
	input := `{"validator_updates":[{"pub_key":{"ed25519":"aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="},"power":100}],"valset_update_id":"1"}`

	vsc, err := UnmarshalValidatorSetChangePacketData([]byte(input))
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if vsc.ValidatorUpdates[0].Power != 100 {
		t.Errorf("Power: got %d, want 100", vsc.ValidatorUpdates[0].Power)
	}
}

// TestUnmarshalProviderFormatMissingPower tests that a missing power field
// defaults to 0 (validator removal). The provider omits zero-valued fields.
func TestUnmarshalProviderFormatMissingPower(t *testing.T) {
	input := `{"validator_updates":[{"pub_key":{"ed25519":"aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="}}],"valset_update_id":"1"}`

	vsc, err := UnmarshalValidatorSetChangePacketData([]byte(input))
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if vsc.ValidatorUpdates[0].Power != 0 {
		t.Errorf("Power: got %d, want 0", vsc.ValidatorUpdates[0].Power)
	}
}

// TestUnmarshalValsetUpdateIdAsNumber tests valset_update_id as a JSON number.
func TestUnmarshalValsetUpdateIdAsNumber(t *testing.T) {
	input := `{"validator_updates":[],"valset_update_id":42}`

	vsc, err := UnmarshalValidatorSetChangePacketData([]byte(input))
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if vsc.ValsetUpdateId != 42 {
		t.Errorf("ValsetUpdateId: got %d, want 42", vsc.ValsetUpdateId)
	}
}

// TestUnmarshalSecp256k1Key tests parsing a secp256k1 key from the provider.
func TestUnmarshalSecp256k1Key(t *testing.T) {
	input := `{"validator_updates":[{"pub_key":{"secp256k1":"A7x3FJxIMWJM1xymAKRHLiPMqxR0NQKX2gjHMYNKHZk="},"power":"75"}],"valset_update_id":"5"}`

	vsc, err := UnmarshalValidatorSetChangePacketData([]byte(input))
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if vsc.ValidatorUpdates[0].PubKey != "secp256k1:A7x3FJxIMWJM1xymAKRHLiPMqxR0NQKX2gjHMYNKHZk=" {
		t.Errorf("PubKey: got %q", vsc.ValidatorUpdates[0].PubKey)
	}
	if vsc.ValidatorUpdates[0].Power != 75 {
		t.Errorf("Power: got %d, want 75", vsc.ValidatorUpdates[0].Power)
	}
}

func TestUnmarshalInvalidJSON(t *testing.T) {
	tests := []struct {
		name  string
		input string
	}{
		{
			name:  "empty input",
			input: "",
		},
		{
			name:  "not json",
			input: "not json at all",
		},
		{
			name:  "missing valset_update_id",
			input: `{"validator_updates": []}`,
		},
		{
			name:  "missing validator_updates",
			input: `{"valset_update_id": "1"}`,
		},
		{
			name:  "invalid valset_update_id type",
			input: `{"validator_updates": [], "valset_update_id": "abc"}`,
		},
		{
			name:  "missing pub_key in update",
			input: `{"validator_updates": [{"power": "100"}], "valset_update_id": "1"}`,
		},
		{
			name:  "invalid pub_key - not object or string",
			input: `{"validator_updates": [{"pub_key": 123, "power": "100"}], "valset_update_id": "1"}`,
		},
		{
			name:  "invalid pub_key - wrong key type in object",
			input: `{"validator_updates": [{"pub_key": {"rsa": "AAAA"}, "power": "100"}], "valset_update_id": "1"}`,
		},
		{
			name:  "invalid power value",
			input: `{"validator_updates": [{"pub_key": {"ed25519": "AAAA"}, "power": "notanumber"}], "valset_update_id": "1"}`,
		},
		{
			name:  "invalid base64 in pub_key",
			input: `{"validator_updates": [{"pub_key": {"ed25519": "not valid base64!!!"}, "power": "100"}], "valset_update_id": "1"}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := UnmarshalValidatorSetChangePacketData([]byte(tt.input))
			if err == nil {
				t.Error("expected error, got nil")
			}
		})
	}
}

// TestUnmarshalLegacyStringPubKey tests that the legacy format with pub_key
// as a simple string (e.g. from tests) still works via backward compatibility.
func TestUnmarshalLegacyStringPubKey(t *testing.T) {
	// Legacy format: pub_key as a plain canonical string
	input := `{"validator_updates":[{"pub_key":"ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=","power":"100"}],"valset_update_id":"1"}`

	vsc, err := UnmarshalValidatorSetChangePacketData([]byte(input))
	if err != nil {
		t.Fatalf("UnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if vsc.ValidatorUpdates[0].PubKey != "ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=" {
		t.Errorf("PubKey: got %q", vsc.ValidatorUpdates[0].PubKey)
	}
}

func TestAccumulateChanges(t *testing.T) {
	t.Run("empty current and incoming", func(t *testing.T) {
		result := AccumulateChanges(nil, nil)
		if len(result) != 0 {
			t.Errorf("expected empty result, got %d items", len(result))
		}
	})

	t.Run("empty current with incoming", func(t *testing.T) {
		incoming := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100},
			{PubKey: MakePubKey("ed25519", "BBBB"), Power: 50},
		}
		result := AccumulateChanges(nil, incoming)
		if len(result) != 2 {
			t.Fatalf("expected 2 results, got %d", len(result))
		}
		// Should be sorted by descending power
		if result[0].Power != 100 {
			t.Errorf("expected first result power 100, got %d", result[0].Power)
		}
		if result[1].Power != 50 {
			t.Errorf("expected second result power 50, got %d", result[1].Power)
		}
	})

	t.Run("incoming overrides current", func(t *testing.T) {
		current := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100},
			{PubKey: MakePubKey("ed25519", "BBBB"), Power: 50},
		}
		incoming := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 200}, // override
		}
		result := AccumulateChanges(current, incoming)
		if len(result) != 2 {
			t.Fatalf("expected 2 results, got %d", len(result))
		}
		// ed25519:AAAA should have updated power 200
		found := false
		for _, vu := range result {
			if vu.PubKey == MakePubKey("ed25519", "AAAA") {
				if vu.Power != 200 {
					t.Errorf("expected ed25519:AAAA power 200, got %d", vu.Power)
				}
				found = true
			}
		}
		if !found {
			t.Error("ed25519:AAAA not found in results")
		}
	})

	t.Run("merge current and new validators", func(t *testing.T) {
		current := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100},
		}
		incoming := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "BBBB"), Power: 50},
		}
		result := AccumulateChanges(current, incoming)
		if len(result) != 2 {
			t.Fatalf("expected 2 results, got %d", len(result))
		}
	})

	t.Run("deterministic sort order", func(t *testing.T) {
		updates := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "CCCC"), Power: 50},
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 50},
			{PubKey: MakePubKey("ed25519", "BBBB"), Power: 100},
		}
		result := AccumulateChanges(nil, updates)
		if len(result) != 3 {
			t.Fatalf("expected 3 results, got %d", len(result))
		}
		// First: ed25519:BBBB (power 100)
		if result[0].PubKey != MakePubKey("ed25519", "BBBB") {
			t.Errorf("expected first result ed25519:BBBB, got %s", result[0].PubKey)
		}
		// For equal power 50, descending pubkey: ed25519:CCCC before ed25519:AAAA
		if result[1].PubKey != MakePubKey("ed25519", "CCCC") {
			t.Errorf("expected second result ed25519:CCCC, got %s", result[1].PubKey)
		}
		if result[2].PubKey != MakePubKey("ed25519", "AAAA") {
			t.Errorf("expected third result ed25519:AAAA, got %s", result[2].PubKey)
		}
	})
}

func TestApplyValidatorChanges(t *testing.T) {
	// Reset store for each test
	resetStore := func() {
		store.validators = nil
		store.validators = newTree()
		store.pendingChanges = nil
		store.pendingChanges = newTree()
	}

	t.Run("add new validators", func(t *testing.T) {
		resetStore()

		changes := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100},
			{PubKey: MakePubKey("ed25519", "BBBB"), Power: 50},
		}
		applied := applyValidatorChanges(changes)
		if len(applied) != 2 {
			t.Fatalf("expected 2 applied, got %d", len(applied))
		}
		if GetCCValidatorCount() != 2 {
			t.Errorf("expected 2 validators, got %d", GetCCValidatorCount())
		}
		if GetTotalVotingPower() != 150 {
			t.Errorf("expected total power 150, got %d", GetTotalVotingPower())
		}
	})

	t.Run("update existing validator power", func(t *testing.T) {
		resetStore()

		// Add initial validator
		setCCValidator(CrossChainValidator{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100})

		// Update power
		changes := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 200},
		}
		applied := applyValidatorChanges(changes)
		if len(applied) != 1 {
			t.Fatalf("expected 1 applied, got %d", len(applied))
		}
		val, found := getCCValidator(MakePubKey("ed25519", "AAAA"))
		if !found {
			t.Fatal("validator not found after update")
		}
		if val.Power != 200 {
			t.Errorf("expected power 200, got %d", val.Power)
		}
	})

	t.Run("remove existing validator with zero power", func(t *testing.T) {
		resetStore()

		// Add initial validator
		setCCValidator(CrossChainValidator{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100})

		changes := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 0},
		}
		applied := applyValidatorChanges(changes)
		if len(applied) != 1 {
			t.Fatalf("expected 1 applied, got %d", len(applied))
		}
		_, found := getCCValidator(MakePubKey("ed25519", "AAAA"))
		if found {
			t.Error("validator should have been removed")
		}
		if GetCCValidatorCount() != 0 {
			t.Errorf("expected 0 validators, got %d", GetCCValidatorCount())
		}
	})

	t.Run("skip zero power for non-existing validator", func(t *testing.T) {
		resetStore()

		changes := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "ZZZZ"), Power: 0},
		}
		applied := applyValidatorChanges(changes)
		if len(applied) != 0 {
			t.Fatalf("expected 0 applied, got %d", len(applied))
		}
		if GetCCValidatorCount() != 0 {
			t.Errorf("expected 0 validators, got %d", GetCCValidatorCount())
		}
	})

	t.Run("mixed operations", func(t *testing.T) {
		resetStore()

		// Set up initial validators
		setCCValidator(CrossChainValidator{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100})
		setCCValidator(CrossChainValidator{PubKey: MakePubKey("ed25519", "BBBB"), Power: 50})
		setCCValidator(CrossChainValidator{PubKey: MakePubKey("ed25519", "CCCC"), Power: 75})

		changes := []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "AAAA"), Power: 0},   // remove
			{PubKey: MakePubKey("ed25519", "BBBB"), Power: 200}, // update
			{PubKey: MakePubKey("ed25519", "DDDD"), Power: 30},  // add new
			{PubKey: MakePubKey("ed25519", "EEEE"), Power: 0},   // skip (non-existing, zero power)
		}
		applied := applyValidatorChanges(changes)
		if len(applied) != 3 {
			t.Fatalf("expected 3 applied, got %d", len(applied))
		}

		// AAAA should be removed
		_, found := getCCValidator(MakePubKey("ed25519", "AAAA"))
		if found {
			t.Error("AAAA should have been removed")
		}

		// BBBB should be updated
		val, found := getCCValidator(MakePubKey("ed25519", "BBBB"))
		if !found {
			t.Fatal("BBBB not found")
		}
		if val.Power != 200 {
			t.Errorf("BBBB expected power 200, got %d", val.Power)
		}

		// CCCC should be unchanged
		val, found = getCCValidator(MakePubKey("ed25519", "CCCC"))
		if !found {
			t.Fatal("CCCC not found")
		}
		if val.Power != 75 {
			t.Errorf("CCCC expected power 75, got %d", val.Power)
		}

		// DDDD should be added
		val, found = getCCValidator(MakePubKey("ed25519", "DDDD"))
		if !found {
			t.Fatal("DDDD not found")
		}
		if val.Power != 30 {
			t.Errorf("DDDD expected power 30, got %d", val.Power)
		}

		// Total: BBBB(200) + CCCC(75) + DDDD(30) = 305
		if GetTotalVotingPower() != 305 {
			t.Errorf("expected total power 305, got %d", GetTotalVotingPower())
		}
		if GetCCValidatorCount() != 3 {
			t.Errorf("expected 3 validators, got %d", GetCCValidatorCount())
		}
	})
}

func TestSerializeValidatorSet(t *testing.T) {
	// Reset store
	store.validators = nil
	store.validators = newTree()

	setCCValidator(CrossChainValidator{PubKey: MakePubKey("ed25519", "AAAA"), Power: 100})
	setCCValidator(CrossChainValidator{PubKey: MakePubKey("ed25519", "BBBB"), Power: 50})

	entries := serializeValidatorSet()
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}

	// AVL tree iterates in sorted key order (ascending by pubkey)
	expected := []string{
		"ed25519:AAAA:100",
		"ed25519:BBBB:50",
	}
	for i, e := range entries {
		if e != expected[i] {
			t.Errorf("entry #%d: got %q, want %q", i, e, expected[i])
		}
	}
}

func TestSortValidatorUpdates(t *testing.T) {
	updates := []ValidatorUpdate{
		{PubKey: MakePubKey("ed25519", "AAAA"), Power: 50},
		{PubKey: MakePubKey("ed25519", "BBBB"), Power: 100},
		{PubKey: MakePubKey("ed25519", "CCCC"), Power: 50},
		{PubKey: MakePubKey("ed25519", "DDDD"), Power: 200},
	}

	sortValidatorUpdates(updates)

	// Expected order: descending power, then descending pubkey for ties
	expectedOrder := []struct {
		PubKey string
		Power  int64
	}{
		{MakePubKey("ed25519", "DDDD"), 200},
		{MakePubKey("ed25519", "BBBB"), 100},
		{MakePubKey("ed25519", "CCCC"), 50},
		{MakePubKey("ed25519", "AAAA"), 50},
	}

	for i, exp := range expectedOrder {
		if updates[i].PubKey != exp.PubKey || updates[i].Power != exp.Power {
			t.Errorf("position %d: got {%s, %d}, want {%s, %d}",
				i, updates[i].PubKey, updates[i].Power, exp.PubKey, exp.Power)
		}
	}
}

func TestHighestValsetUpdateID(t *testing.T) {
	// Reset
	store.highestValsetUpdateID = 0

	if GetHighestValsetUpdateID() != 0 {
		t.Errorf("expected 0, got %d", GetHighestValsetUpdateID())
	}

	setHighestValsetUpdateID(5)
	if GetHighestValsetUpdateID() != 5 {
		t.Errorf("expected 5, got %d", GetHighestValsetUpdateID())
	}

	setHighestValsetUpdateID(10)
	if GetHighestValsetUpdateID() != 10 {
		t.Errorf("expected 10, got %d", GetHighestValsetUpdateID())
	}

	// Reset for other tests
	store.highestValsetUpdateID = 0
}

func TestMakePubKey(t *testing.T) {
	pk := MakePubKey("ed25519", "AAAA")
	if pk != "ed25519:AAAA" {
		t.Errorf("expected 'ed25519:AAAA', got %q", pk)
	}

	pk2 := MakePubKey("secp256k1", "BBBB")
	if pk2 != "secp256k1:BBBB" {
		t.Errorf("expected 'secp256k1:BBBB', got %q", pk2)
	}
}

// newTree is a helper that returns a fresh AVL tree for test resets.
func newTree() *avl.Tree {
	return avl.NewTree()
}
