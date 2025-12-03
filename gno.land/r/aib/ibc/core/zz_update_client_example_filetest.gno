package main

import (
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

func main() {
	var (
		clientID  = "07-tendermint-1"         // XXX update
		chainID   = "chain-id-2"              // XXX update
		timestamp = time.Now()                // XXX update
		height    = types.Height{2, 5}        // XXX update
		valset    = &tendermint.ValidatorSet{ // XXX update
			Validators: []*tendermint.Validator{
				{
					Address:     tmtesting.GenAddr("val1"),
					PubKey:      tmtesting.GenPubkey("val1_pubkey"),
					VotingPower: 2,
				},
				{
					Address:     tmtesting.GenAddr("val2"),
					PubKey:      tmtesting.GenPubkey("val2_pubkey"),
					VotingPower: 3,
				},
			},
			Proposer: &tendermint.Validator{
				Address:     tmtesting.GenAddr("val1"),
				PubKey:      tmtesting.GenPubkey("val1_pubkey"),
				VotingPower: 2,
			},
			TotalVotingPower: 5,
		}
		trustedHeight = types.Height{2, 2}        // XXX update
		trustedValset = &tendermint.ValidatorSet{ // XXX update
			Validators: []*tendermint.Validator{
				{
					Address:     tmtesting.GenAddr("val1"),
					PubKey:      tmtesting.GenPubkey("val1_pubkey"),
					VotingPower: 2,
				},
				{
					Address:     tmtesting.GenAddr("val2"),
					PubKey:      tmtesting.GenPubkey("val2_pubkey"),
					VotingPower: 3,
				},
			},
			Proposer: &tendermint.Validator{
				Address:     tmtesting.GenAddr("val1"),
				PubKey:      tmtesting.GenPubkey("val1_pubkey"),
				VotingPower: 2,
			},
			TotalVotingPower: 5,
		}
		msgHeader = &tendermint.MsgHeader{
			Header: &tendermint.Header{
				Version: tendermint.Consensus{
					Block: tendermint.BlockProtocol,
					App:   1, //NOTE no idea what to put there, sounds unused
				},
				ChainID: chainID,
				Height:  height.RevisionHeight,
				Time:    timestamp,
				LastBlockID: tendermint.BlockID{
					Hash: tmtesting.Hash("last_block_hash"),
					PartSetHeader: tendermint.PartSetHeader{
						Total: 2,
						Hash:  tmtesting.Hash("last_block_partset_header_hash"),
					},
				},
				LastCommitHash:     tmtesting.Hash("last_commit_hash"), //XXX update
				DataHash:           tmtesting.Hash("data_hash"),        //XXX update
				ValidatorsHash:     valset.Hash(),
				NextValidatorsHash: valset.Hash(),
				ConsensusHash:      tmtesting.Hash("consensus_hash"),    // XXX update
				AppHash:            tmtesting.Hash("app_hash"),          // XXX update
				LastResultsHash:    tmtesting.Hash("last_results_hash"), //XXX update
				EvidenceHash:       tmtesting.Hash("evidence_hash"),     //XXX update
				ProposerAddress:    tmtesting.GenAddr("proposer"),       // XXX update
			},
			Commit: &tendermint.Commit{
				Height: height.RevisionHeight,
				Round:  1,
				BlockID: tendermint.BlockID{
					Hash: tmtesting.Hash("last_block_partset_header_hash"), //XXX update
					PartSetHeader: tendermint.PartSetHeader{
						Total: 5,
						Hash:  tmtesting.Hash("last_block_partset_header_hash"), //XXX update
					},
				},
				Signatures: []tendermint.CommitSig{
					{
						BlockIDFlag:      tendermint.BlockIDFlagCommit,
						ValidatorAddress: tmtesting.GenAddr("val1"),                          // XXX update
						Signature:        tmtesting.GenSignature("valsign1"),                 // XXX update
						Timestamp:        tmtesting.ToTime("2025-09-25T07:55:57.306746166Z"), //XXX update
					},
					{
						BlockIDFlag:      tendermint.BlockIDFlagCommit,
						ValidatorAddress: tmtesting.GenAddr("val2"),                          // XXX update
						Signature:        tmtesting.GenSignature("valsign2"),                 // XXX update
						Timestamp:        tmtesting.ToTime("2025-09-25T07:55:57.306746166Z"), //XXX update
					},
				},
			},
			ValidatorSet:      valset,
			TrustedHeight:     trustedHeight,
			TrustedValidators: trustedValset,
		}
	)
	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// expected BlockID#Hash and Header#Hash to be the same, got "b40edd05fbc1dba702520fbf71142c39ebe97400a1806a842a7c54f6d97fb519" != "fb33f6107d92ab1b8e8d3b2ad622f64a06bff39d10f2cb7257b3cc327fa7107e"
