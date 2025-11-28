package merkle

import (
	"encoding/hex"
	"testing"

	"gno.land/p/nt/uassert"
)

func TestHashFromByteSlices(t *testing.T) {
	tests := []struct {
		name       string
		slices     [][]byte
		expectHash string // in hex format
	}{
		{
			name:       "nil",
			slices:     nil,
			expectHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		},
		{
			name:   "empty",
			slices: [][]byte{}, expectHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		},
		{
			name:       "single",
			slices:     [][]byte{{1, 2, 3}},
			expectHash: "054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8",
		},
		{
			name:       "single blank",
			slices:     [][]byte{{}},
			expectHash: "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
		},
		{
			name:       "two",
			slices:     [][]byte{{1, 2, 3}, {4, 5, 6}},
			expectHash: "82e6cfce00453804379b53962939eaa7906b39904be0813fcadd31b100773c4b",
		},
		{
			name:       "many",
			slices:     [][]byte{{1, 2}, {3, 4}, {5, 6}, {7, 8}, {9, 10}},
			expectHash: "f326493eceab4f2d9ffbc78c59432a0a005d6ea98392045c74df5d14a113be18",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hash := HashFromByteSlices(tt.slices)

			uassert.Equal(t, tt.expectHash, hex.EncodeToString(hash))
		})
	}
}
