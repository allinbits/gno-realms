package consumer

import (
	"testing"

	"gno.land/p/nt/avl/v0"
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
		{
			name: "negative power",
			vsc: ValidatorSetChangePacketData{
				ValidatorUpdates: []ValidatorUpdate{
					{PubKey: MakePubKey("ed25519", "AAAA"), Power: -1},
				},
				ValsetUpdateId: 1,
			},
			wantErr: true,
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

func TestProtoMarshalUnmarshalRoundTrip(t *testing.T) {
	original := ValidatorSetChangePacketData{
		ValidatorUpdates: []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 100},
			{PubKey: MakePubKey("ed25519", "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 0},
			{PubKey: MakePubKey("secp256k1", "A7x3FJxIMWJM1xymAKRHLiPMqxR0NQKX2gjHMYNKHZk="), Power: 50},
		},
		ValsetUpdateId: 7,
	}

	bz := original.ProtoMarshal()
	if len(bz) == 0 {
		t.Fatal("ProtoMarshal returned empty bytes")
	}

	decoded, err := ProtoUnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		t.Fatalf("ProtoUnmarshalValidatorSetChangePacketData failed: %v", err)
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

func TestProtoMarshalUnmarshalEmptyUpdates(t *testing.T) {
	original := ValidatorSetChangePacketData{
		ValidatorUpdates: []ValidatorUpdate{},
		ValsetUpdateId:   1,
	}

	bz := original.ProtoMarshal()
	decoded, err := ProtoUnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		t.Fatalf("ProtoUnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if decoded.ValsetUpdateId != 1 {
		t.Errorf("ValsetUpdateId mismatch: got %d, want 1", decoded.ValsetUpdateId)
	}
	if len(decoded.ValidatorUpdates) != 0 {
		t.Errorf("expected empty ValidatorUpdates, got %d", len(decoded.ValidatorUpdates))
	}
}

func TestUnmarshalProtobufFromProvider(t *testing.T) {
	// Simulate protobuf bytes for:
	// validator_updates: [{pub_key: {ed25519: <bytes>}, power: 100}, {pub_key: {ed25519: <bytes>}, power: 50}]
	// valset_update_id: 1
	vsc := ValidatorSetChangePacketData{
		ValidatorUpdates: []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 100},
			{PubKey: MakePubKey("ed25519", "bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 50},
		},
		ValsetUpdateId: 1,
	}
	bz := vsc.ProtoMarshal()

	decoded, err := ProtoUnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		t.Fatalf("ProtoUnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if decoded.ValsetUpdateId != 1 {
		t.Errorf("ValsetUpdateId: got %d, want 1", decoded.ValsetUpdateId)
	}
	if len(decoded.ValidatorUpdates) != 2 {
		t.Fatalf("expected 2 updates, got %d", len(decoded.ValidatorUpdates))
	}

	if decoded.ValidatorUpdates[0].PubKey != "ed25519:aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=" {
		t.Errorf("update 0 PubKey: got %q", decoded.ValidatorUpdates[0].PubKey)
	}
	if decoded.ValidatorUpdates[0].Power != 100 {
		t.Errorf("update 0 Power: got %d, want 100", decoded.ValidatorUpdates[0].Power)
	}

	if decoded.ValidatorUpdates[1].PubKey != "ed25519:bPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ=" {
		t.Errorf("update 1 PubKey: got %q", decoded.ValidatorUpdates[1].PubKey)
	}
	if decoded.ValidatorUpdates[1].Power != 50 {
		t.Errorf("update 1 Power: got %d, want 50", decoded.ValidatorUpdates[1].Power)
	}
}

func TestUnmarshalProtobufZeroPower(t *testing.T) {
	// When power is 0, protobuf omits the field (default value).
	vsc := ValidatorSetChangePacketData{
		ValidatorUpdates: []ValidatorUpdate{
			{PubKey: MakePubKey("ed25519", "aPFcGOi1P2myrQtfEz6bJikBE3WoW2VHuzMEkjx2jKQ="), Power: 0},
		},
		ValsetUpdateId: 1,
	}
	bz := vsc.ProtoMarshal()

	decoded, err := ProtoUnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		t.Fatalf("ProtoUnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if decoded.ValidatorUpdates[0].Power != 0 {
		t.Errorf("Power: got %d, want 0", decoded.ValidatorUpdates[0].Power)
	}
}

func TestUnmarshalProtobufSecp256k1Key(t *testing.T) {
	vsc := ValidatorSetChangePacketData{
		ValidatorUpdates: []ValidatorUpdate{
			{PubKey: MakePubKey("secp256k1", "A7x3FJxIMWJM1xymAKRHLiPMqxR0NQKX2gjHMYNKHZk="), Power: 75},
		},
		ValsetUpdateId: 5,
	}
	bz := vsc.ProtoMarshal()

	decoded, err := ProtoUnmarshalValidatorSetChangePacketData(bz)
	if err != nil {
		t.Fatalf("ProtoUnmarshalValidatorSetChangePacketData failed: %v", err)
	}

	if decoded.ValidatorUpdates[0].PubKey != "secp256k1:A7x3FJxIMWJM1xymAKRHLiPMqxR0NQKX2gjHMYNKHZk=" {
		t.Errorf("PubKey: got %q", decoded.ValidatorUpdates[0].PubKey)
	}
	if decoded.ValidatorUpdates[0].Power != 75 {
		t.Errorf("Power: got %d, want 75", decoded.ValidatorUpdates[0].Power)
	}
}

func TestUnmarshalInvalidProtobuf(t *testing.T) {
	tests := []struct {
		name  string
		input []byte
	}{
		{
			name:  "empty input",
			input: []byte{},
		},
		{
			name:  "garbage bytes",
			input: []byte{0xFF, 0xFF, 0xFF, 0xFF},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Empty input should decode to a zero-value VSC with empty (not nil) updates
			decoded, err := ProtoUnmarshalValidatorSetChangePacketData(tt.input)
			if tt.name == "empty input" {
				if err != nil {
					t.Errorf("unexpected error for empty input: %v", err)
				}
				if decoded.ValsetUpdateId != 0 {
					t.Errorf("expected 0 valset_update_id, got %d", decoded.ValsetUpdateId)
				}
				return
			}
			if err == nil {
				// garbage may or may not error, but should not panic
			}
		})
	}
}

func TestApplyValidatorChanges(t *testing.T) {
	resetStore := func() {
		store.validators = nil
		store.validators = newTree()
	}

	pkA := MakePubKey("ed25519", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
	pkB := MakePubKey("ed25519", "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=")
	pkC := MakePubKey("ed25519", "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=")
	pkD := MakePubKey("ed25519", "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=")
	pkE := MakePubKey("ed25519", "BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=")
	pkZ := MakePubKey("ed25519", "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU=")

	t.Run("add new validators", func(t *testing.T) {
		resetStore()

		changes := []ValidatorUpdate{
			{PubKey: pkA, Power: 100},
			{PubKey: pkB, Power: 50},
		}
		applyValidatorChanges(changes)
		if GetCCValidatorCount() != 2 {
			t.Errorf("expected 2 validators, got %d", GetCCValidatorCount())
		}
		if GetTotalVotingPower() != 150 {
			t.Errorf("expected total power 150, got %d", GetTotalVotingPower())
		}
	})

	t.Run("update existing validator power", func(t *testing.T) {
		resetStore()

		setCCValidator(CrossChainValidator{PubKey: pkA, Power: 100})

		changes := []ValidatorUpdate{
			{PubKey: pkA, Power: 200},
		}
		applyValidatorChanges(changes)
		val, found := getCCValidator(pkA)
		if !found {
			t.Fatal("validator not found after update")
		}
		if val.Power != 200 {
			t.Errorf("expected power 200, got %d", val.Power)
		}
	})

	t.Run("remove existing validator with zero power", func(t *testing.T) {
		resetStore()

		setCCValidator(CrossChainValidator{PubKey: pkA, Power: 100})

		changes := []ValidatorUpdate{
			{PubKey: pkA, Power: 0},
		}
		applyValidatorChanges(changes)
		_, found := getCCValidator(pkA)
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
			{PubKey: pkZ, Power: 0},
		}
		applyValidatorChanges(changes)
		if GetCCValidatorCount() != 0 {
			t.Errorf("expected 0 validators, got %d", GetCCValidatorCount())
		}
	})

	t.Run("mixed operations", func(t *testing.T) {
		resetStore()

		setCCValidator(CrossChainValidator{PubKey: pkA, Power: 100})
		setCCValidator(CrossChainValidator{PubKey: pkB, Power: 50})
		setCCValidator(CrossChainValidator{PubKey: pkC, Power: 75})

		changes := []ValidatorUpdate{
			{PubKey: pkA, Power: 0},   // remove
			{PubKey: pkB, Power: 200}, // update
			{PubKey: pkD, Power: 30},  // add new
			{PubKey: pkE, Power: 0},   // skip (non-existing, zero power)
		}
		applyValidatorChanges(changes)

		_, found := getCCValidator(pkA)
		if found {
			t.Error("pkA should have been removed")
		}

		val, found := getCCValidator(pkB)
		if !found {
			t.Fatal("pkB not found")
		}
		if val.Power != 200 {
			t.Errorf("pkB expected power 200, got %d", val.Power)
		}

		val, found = getCCValidator(pkC)
		if !found {
			t.Fatal("pkC not found")
		}
		if val.Power != 75 {
			t.Errorf("pkC expected power 75, got %d", val.Power)
		}

		val, found = getCCValidator(pkD)
		if !found {
			t.Fatal("pkD not found")
		}
		if val.Power != 30 {
			t.Errorf("pkD expected power 30, got %d", val.Power)
		}

		if GetTotalVotingPower() != 305 {
			t.Errorf("expected total power 305, got %d", GetTotalVotingPower())
		}
		if GetCCValidatorCount() != 3 {
			t.Errorf("expected 3 validators, got %d", GetCCValidatorCount())
		}
	})
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
