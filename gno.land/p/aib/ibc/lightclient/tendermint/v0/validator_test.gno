package tendermint

import (
	"encoding/hex"
	"math"
	"strings"
	"testing"
)

func TestValidatorSetHash(t *testing.T) {
	var (
		// priv=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==
		val1 = NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
			"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)
		// priv=nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
		val2 = NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
			"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 1)
		valset = NewValset(val1, val2)
	)

	hash := hex.EncodeToString(valset.Hash())

	expectedHash := "3897c9b87e9d7e2648d9dd2e031a9a9aa7c856a578738a040198a0bc9f14a854"
	if hash != expectedHash {
		t.Errorf("Expected %v, got '%s'", expectedHash, hash)
	}
}

func TestValidatorBytes(t *testing.T) {
	// priv=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==
	val := NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=", "VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)

	bz := val.Bytes()

	encodedBz := hex.EncodeToString(bz)
	expectedBz := "0a220a2054ca4ed11ce666ee0e315bec9e261d78eff678ffa1d717a801c1c14d90bb19fc1001"
	if encodedBz != expectedBz {
		t.Errorf("Expected %v, got '%s'", expectedBz, encodedBz)
	}
}

func TestVotingPowerThreshold(t *testing.T) {
	newVal := func(vp int64) *Validator {
		return &Validator{Address: []byte("addr"), PubKey: []byte("pubkey"), VotingPower: vp}
	}
	testCases := []struct {
		name        string
		vals        *ValidatorSet
		num, den    uint64
		expected    int64
		expectedErr string
	}{
		{
			name:     "2/3",
			vals:     NewValset(newVal(30), newVal(30), newVal(30), newVal(10)),
			num:      2,
			den:      3,
			expected: 66,
		},
		{
			name:     "1/3",
			vals:     NewValset(newVal(30), newVal(30), newVal(30), newVal(10)),
			num:      1,
			den:      3,
			expected: 33,
		},
		{
			name:        "negative validator voting power",
			vals:        NewValset(newVal(30), newVal(-10)),
			num:         2,
			den:         3,
			expectedErr: "validator #1 has negative voting power -10",
		},
		{
			name:        "total voting power exceeds maximum",
			vals:        NewValset(newVal(MaxTotalVotingPower), newVal(1)),
			num:         2,
			den:         3,
			expectedErr: "total voting power exceeds maximum",
		},
		{
			name:        "total voting power wraps int64",
			vals:        NewValset(newVal(MaxTotalVotingPower), newVal(math.MaxInt64), newVal(math.MaxInt64)),
			num:         2,
			den:         3,
			expectedErr: "total voting power exceeds maximum",
		},
		{
			name:     "maximum total voting power",
			vals:     NewValset(newVal(MaxTotalVotingPower)),
			num:      2,
			den:      3,
			expected: MaxTotalVotingPower * 2 / 3,
		},
		{
			name:        "numerator overflows",
			vals:        NewValset(newVal(MaxTotalVotingPower)),
			num:         9,
			den:         10,
			expectedErr: "voting power threshold overflows",
		},
		{
			name:        "denominator overflows int64",
			vals:        NewValset(newVal(10)),
			num:         1,
			den:         1 << 63,
			expectedErr: "invalid voting power threshold denominator",
		},
		{
			name:     "empty set",
			vals:     &ValidatorSet{},
			num:      2,
			den:      3,
			expected: 0,
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := votingPowerThreshold(tc.vals, tc.num, tc.den)
			if tc.expectedErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.expectedErr) {
					t.Fatalf("expected error %q, got %v", tc.expectedErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.expected {
				t.Errorf("expected %d, got %d", tc.expected, got)
			}
		})
	}
}
