package testing

import (
	"crypto/sha256"
	"encoding/base64"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
)

func NewMsgHeader(chainID string, timestamp time.Time,
	apphash []byte, height uint64, trustedHeight types.Height,
	valset, trustedValset *tendermint.ValidatorSet,
	signatures []tendermint.CommitSig) *tendermint.MsgHeader {
	header := &tendermint.Header{
		Version: tendermint.Consensus{
			Block: tendermint.BlockProtocol,
			App:   0,
		},
		ChainID: chainID,
		Height:  height,
		Time:    timestamp,
		LastBlockID: tendermint.BlockID{
			Hash: Hash("last_block_hash"),
			PartSetHeader: tendermint.PartSetHeader{
				Total: 1,
				Hash:  Hash("last_block_parset_hash"),
			},
		},
		LastCommitHash:     Hash("last_commit_hash"),
		DataHash:           Hash("data_hash"),
		ValidatorsHash:     valset.Hash(),
		NextValidatorsHash: trustedValset.Hash(),
		ConsensusHash:      Hash("consensus_hash"),
		AppHash:            apphash,
		LastResultsHash:    Hash("last_result_hash"),
		EvidenceHash:       Hash("evidence_hash"),
		ProposerAddress:    valset.Proposer.Address,
	}

	return &tendermint.MsgHeader{
		Header: header,
		Commit: &tendermint.Commit{
			Height: height,
			Round:  0,
			BlockID: tendermint.BlockID{
				Hash: header.Hash(), // compute expected block hash
				PartSetHeader: tendermint.PartSetHeader{
					Total: 1,
					Hash:  Hash("block_parset_hash"),
				},
			},
			Signatures: signatures,
		},
		ValidatorSet:      valset,
		TrustedHeight:     trustedHeight,
		TrustedValidators: trustedValset,
	}
}

func NewClientState(chainID string, height types.Height) tendermint.ClientState {
	return tendermint.ClientState{
		ChainID:         chainID,
		TrustLevel:      tendermint.DefaultTrustLevel,
		UnbondingPeriod: time.Hour * 3,
		TrustingPeriod:  time.Hour,
		MaxClockDrift:   time.Hour,
		LatestHeight:    height,
		ProofSpecs:      ics23.GetSDKProofSpecs(),
	}
}

func GenValset() *tendermint.ValidatorSet {
	var (
		val1 = &tendermint.Validator{
			Address:     GenAddr("val1"),
			PubKey:      GenPubkey("val1_pubkey"),
			VotingPower: 2,
		}
		val2 = &tendermint.Validator{
			Address:     GenAddr("val2"),
			PubKey:      GenPubkey("val2_pubkey"),
			VotingPower: 3,
		}
	)
	return tendermint.NewValset(val1, val2)
}

func GenConsensusState(timestamp time.Time, apphash, valsethash []byte) tendermint.ConsensusState {
	return tendermint.ConsensusState{
		Timestamp:          timestamp,
		Root:               tendermint.MerkleRoot{Hash: apphash},
		NextValidatorsHash: valsethash,
	}
}

// TODO remove?
func GenMsgHeader(chainID string, timestamp time.Time, apphash []byte,
	height uint64, trustedHeight types.Height,
	valset, trustedValset *tendermint.ValidatorSet) *tendermint.MsgHeader {
	var (
		signatures = []tendermint.CommitSig{
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[0].Address,
				Timestamp:        ToTime("2025-09-25T07:55:57.306746166Z"),
				Signature:        B64Dec("qtv1z4S2Q6T87vGQo0lrjRZqv9PrHIji4pTyviMnVyGx9td6eySdzwQwCthwmihU48ebNlFiMlFJ0CT891UmDg=="),
			},
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[1].Address,
				Timestamp:        ToTime("2025-09-25T07:55:57.310583641Z"),
				Signature:        B64Dec("Q5E6Kjma00n/T98rC9qJmoB6JTGFX/IB+mDVs4Wd1h0eJ8fabY/6oI8zdoU6/7W6VR6wjpHyWBsJrpGT6C0LCg=="),
			},
		}
	)
	return NewMsgHeader(chainID, timestamp, apphash, height, trustedHeight,
		valset, trustedValset, signatures)
}

func GenAddr(seed string) []byte {
	return Hash(seed)[:tendermint.AddressSize]
}

func GenSignature(seed string) []byte {
	return Hash(seed)[:tendermint.MaxSignatureSize]
}

func GenPubkey(seed string) []byte {
	return Hash(seed)[:32]
}

func Hash(s string) []byte {
	bz := sha256.Sum256([]byte(s))
	return bz[:]
}

func B64Dec(s string) []byte {
	bz, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return bz
}

func ToTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		panic(err)
	}
	return t
}
