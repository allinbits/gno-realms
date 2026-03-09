package e2e

import (
	"fmt"
	"os"

	"github.com/joho/godotenv"
)

// Config holds e2e test configuration.
type Config struct {
	TestMnemonic   string
	AtomoneChainID string
	GnoChainID     string
	AtomoneRPC     string
	AtomoneREST    string
}

// LoadConfig reads the .env file and returns a Config.
func LoadConfig() (*Config, error) {
	if err := godotenv.Load(); err != nil {
		return nil, fmt.Errorf("load .env: %w", err)
	}

	cfg := &Config{
		TestMnemonic:   os.Getenv("TEST_MNEMONIC"),
		AtomoneChainID: os.Getenv("ATOMONE_CHAIN_ID"),
		GnoChainID:     os.Getenv("GNO_CHAIN_ID"),
		AtomoneRPC:     os.Getenv("ATOMONE_RPC"),
		AtomoneREST:    os.Getenv("ATOMONE_REST"),
	}
	return cfg, nil
}
