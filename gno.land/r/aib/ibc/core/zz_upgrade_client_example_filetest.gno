package main

import (
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/r/aib/ibc/core"
)

func main() {
	// UpgradeClient applies a counterparty chain upgrade to the local
	// client. The relayer reads the upgraded client/consensus state and
	// chained membership proofs from the counterparty's upgrade store at
	// {UpgradePath}/{H}/upgradedClient and {UpgradePath}/{H}/upgradedConsState.
	//
	// Generate the proofs with: go run -C ./cmd/gen-proof . upgrade
	specs := ics23.IavlSpec()

	clientID := "07-tendermint-1" // XXX update

	// The upgraded client state, as committed by the counterparty.
	// Only chain-specified fields (ChainID, UnbondingPeriod, LatestHeight,
	// ProofSpecs, UpgradePath) need accurate values — customizable fields
	// (TrustLevel, TrustingPeriod, MaxClockDrift) are dropped on
	// verification via ZeroCustomFields.
	upgradedClient := tendermint.ClientState{ // XXX update
		ChainID:         "chain-after-upgrade-2",
		TrustLevel:      tendermint.NewFraction(1, 3),
		TrustingPeriod:  2 * 7 * 24 * time.Hour,
		UnbondingPeriod: 3 * 7 * 24 * time.Hour,
		MaxClockDrift:   10 * time.Second,
		LatestHeight:    types.Height{RevisionNumber: 2, RevisionHeight: 1},
		ProofSpecs:      ics23.GetSDKProofSpecs(),
		UpgradePath:     []string{"upgrade", "upgradedIBCState"},
	}

	// The upgraded consensus state. Root is a sentinel value because the
	// upgraded chain hasn't produced any blocks yet at commit time; real
	// roots arrive afterwards via UpdateClient.
	upgradedConsState := tendermint.ConsensusState{ // XXX update
		Timestamp:          time.Unix(1700000000, 0).UTC(),
		Root:               tendermint.NewMerkleRoot([]byte(tendermint.SentinelRoot)),
		NextValidatorsHash: make([]byte, 32),
	}

	// Proof that the upgraded client state was committed under
	//   {UpgradePath[0]}/{UpgradePath[1]}/{H}/upgradedClient
	// in the upgrade IAVL store. Two CommitmentProof entries: the IAVL
	// existence proof for the inner key, and the rootmulti existence
	// proof for the store name.
	proofUpgradeClient := []ics23.CommitmentProof{
		// iavl proof: existence of key `upgradedIBCState/{H}/upgradedClient`
		// in the IAVL store named in UpgradePath[0] (e.g. "upgrade").
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x75\x70\x67\x72\x61\x64\x65\x64\x49\x42\x43\x53\x74\x61\x74\x65\x2f\x31\x30\x30\x2f\x75\x70\x67\x72\x61\x64\x65\x64\x43\x6c\x69\x65\x6e\x74"), // XXX update
				Value: []byte{}, // XXX update — Any-wrapped ZeroCustomFields(upgradedClient) bytes
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00\x02\x02"), // XXX update
				},
				Path: []*ics23.InnerOp{
					// XXX update — depth and number of inner ops depend on
					// the IAVL tree shape at commit time
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte{}, // XXX update
						Suffix: []byte{}, // XXX update
					},
				},
			},
		},
		// rootmulti proof: existence of UpgradePath[0] (the store name)
		// in the chain's multistore root.
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x75\x70\x67\x72\x61\x64\x65"), // XXX update — UpgradePath[0]
				Value: []byte{},                               // XXX update — IAVL store hash
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00"),
				},
				Path: []*ics23.InnerOp{},
			},
		},
	}

	// Same shape as proofUpgradeClient, but for the upgraded consensus
	// state at `upgradedIBCState/{H}/upgradedConsState`.
	proofUpgradeConsState := []ics23.CommitmentProof{
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x75\x70\x67\x72\x61\x64\x65\x64\x49\x42\x43\x53\x74\x61\x74\x65\x2f\x31\x30\x30\x2f\x75\x70\x67\x72\x61\x64\x65\x64\x43\x6f\x6e\x73\x53\x74\x61\x74\x65"), // XXX update
				Value: []byte{}, // XXX update — Any-wrapped upgradedConsState bytes
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00\x02\x02"), // XXX update
				},
				Path: []*ics23.InnerOp{
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte{}, // XXX update
						Suffix: []byte{}, // XXX update
					},
				},
			},
		},
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x75\x70\x67\x72\x61\x64\x65"), // XXX update — UpgradePath[0]
				Value: []byte{},                               // XXX update — IAVL store hash
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00"),
				},
				Path: []*ics23.InnerOp{},
			},
		},
	}

	core.UpgradeClient(cross, clientID,
		upgradedClient, upgradedConsState,
		proofUpgradeClient, proofUpgradeConsState,
	)
}

// Error:
// client 07-tendermint-1 not found
