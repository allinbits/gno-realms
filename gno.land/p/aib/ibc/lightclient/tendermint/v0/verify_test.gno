package tendermint_test

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/lightclient/tendermint/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

// TestVerifyHeaderSingleTrustedSigner ensures a single compromised trusted
// validator cannot authorize a forged header.
//
// The header is at a height non-adjacent to the trusted height, so it must be
// signed by more than 1/3 of the trusted set. Only one trusted validator V
// (power 10 of 100) signs it, along with the two keys of a rogue validator set.
// When ValidatorSet carried a relayer-supplied TotalVotingPower, setting it to
// 1 dropped the needed trusted voting power to 0, letting V alone install an
// arbitrary AppHash; the total is now always computed from the validators.
//
// Signatures are real ed25519 signatures over Commit.BytesToSign, from keys
// with seeds sha256("dora-attacker-1"/"dora-attacker-2"/
// "dora-byzantine-validator") (ed25519 in Gno is Verify-only).
func TestVerifyHeaderSingleTrustedSigner(t *testing.T) {
	var (
		x1Pub    = tmtesting.B64Dec("m0O85ln24L2mdLRqrp7mCg8WT381NWA2ObE9yMJRRTQ=")
		x2Pub    = tmtesting.B64Dec("r0ee/D0rO2V+WIaUE/p7z8dS9AivUF9TlXV6iLc8zrw=")
		vPub     = tmtesting.B64Dec("WlFO8PhaQ/tjDCvYBhLheaCqii2SJR9sAKOpFY8FTCQ=")
		x1Addr   = tmtesting.B64Dec("5aMfZT+4YYxVtA8aFrKSFFLUupA=")
		x2Addr   = tmtesting.B64Dec("z5v03Q7PlduTqm7ng5Om+RBdsmQ=")
		vAddr    = tmtesting.B64Dec("ASaBMIKLbtLAVJ7BKz8aW2QIj1g=")
		sigX1    = tmtesting.B64Dec("0mLqdNst9LDZ6HOJC6LP3b1m1Ei2/4q5hcG1zG7lTNkw6ZSzqoX2oj70MXcCzSTL5eHJ0rXQJRDN/T+C6gFaDQ==")
		sigX2    = tmtesting.B64Dec("KVQRpvNwOpHcTvcPSqwSbUFEd1Hv6D39VGVTwUK8ypAjyK6za3g+I+wK4CJv0JuFd4v5jIn+RVSmVd2ZMDMICQ==")
		sigV     = tmtesting.B64Dec("YX6Z10eUnjeeT5D0KBHT2jPkkSYry/Q6EWTaW++qbZCZyDY/Z3ke1r+bpJAHjinUlY7C/f0UK9PBHqVlTBwbCQ==")
		commitTS = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
	)

	// The trusted validator set, V being the only one to sign.
	a := &tendermint.Validator{Address: tmtesting.Hash("dora-val-a-addr")[:20], PubKey: tmtesting.Hash("dora-val-a"), VotingPower: 30}
	b := &tendermint.Validator{Address: tmtesting.Hash("dora-val-b-addr")[:20], PubKey: tmtesting.Hash("dora-val-b"), VotingPower: 30}
	c := &tendermint.Validator{Address: tmtesting.Hash("dora-val-c-addr")[:20], PubKey: tmtesting.Hash("dora-val-c"), VotingPower: 30}
	newV := func() *tendermint.Validator {
		return &tendermint.Validator{Address: vAddr, PubKey: vPub, VotingPower: 10}
	}

	newMsg := func() *tendermint.MsgHeader {
		trusted := tendermint.NewValset(a, b, c, newV())
		x1 := &tendermint.Validator{Address: x1Addr, PubKey: x1Pub, VotingPower: 100}
		x2 := &tendermint.Validator{Address: x2Addr, PubKey: x2Pub, VotingPower: 100}
		rogue := tendermint.NewValset(x1, x2, newV())
		header := &tendermint.Header{
			Version: tendermint.Consensus{Block: tendermint.BlockProtocol, App: 0},
			ChainID: "gno.land",
			Height:  100,
			Time:    time.Now().Add(time.Minute),
			LastBlockID: tendermint.BlockID{
				Hash:          tmtesting.Hash("last_block_hash"),
				PartSetHeader: tendermint.PartSetHeader{Total: 1, Hash: tmtesting.Hash("last_block_partset_hash")},
			},
			LastCommitHash:     tmtesting.Hash("last_commit_hash"),
			DataHash:           tmtesting.Hash("data_hash"),
			ValidatorsHash:     rogue.Hash(),
			NextValidatorsHash: tmtesting.Hash("dora-evil-next-valset"),
			ConsensusHash:      tmtesting.Hash("consensus_hash"),
			AppHash:            tmtesting.Hash("dora-evil-apphash"),
			LastResultsHash:    tmtesting.Hash("last_results_hash"),
			EvidenceHash:       tmtesting.Hash("evidence_hash"),
			ProposerAddress:    x1Addr,
		}
		commit := &tendermint.Commit{
			Height: 100,
			Round:  0,
			BlockID: tendermint.BlockID{
				Hash:          header.Hash(),
				PartSetHeader: tendermint.PartSetHeader{Total: 1, Hash: tmtesting.Hash("block_partset_hash")},
			},
			Signatures: []tendermint.CommitSig{
				{BlockIDFlag: tendermint.BlockIDFlagCommit, ValidatorAddress: x1Addr, Timestamp: commitTS, Signature: sigX1},
				{BlockIDFlag: tendermint.BlockIDFlagCommit, ValidatorAddress: x2Addr, Timestamp: commitTS, Signature: sigX2},
				{BlockIDFlag: tendermint.BlockIDFlagCommit, ValidatorAddress: vAddr, Timestamp: commitTS, Signature: sigV},
			},
		}
		return &tendermint.MsgHeader{
			Header:            header,
			Commit:            commit,
			ValidatorSet:      rogue,
			TrustedHeight:     types.NewHeight(0, 5),
			TrustedValidators: trusted,
		}
	}

	newClient := func() *tendermint.TMLightClient {
		tm := tendermint.NewTMLightClient()
		clientState := tmtesting.NewClientState("gno.land", types.NewHeight(0, 5))
		consState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("dora-apphash-5"), tendermint.NewValset(a, b, c, newV()).Hash())
		urequire.NoError(t, tm.Initialize(clientState, consState))
		return tm
	}

	msg := newMsg()
	urequire.NoError(t, msg.ValidateBasic())
	tm := newClient()
	urequire.ErrorContains(t, tm.VerifyClientMessage(msg),
		"check trusted validators VP>33: not enough voting power, got 10, needed >33")
	_, found := tm.GetConsensusState(types.NewHeight(0, 100))
	uassert.False(t, found)
}
