package tendermint

import (
	"encoding/hex"
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
