package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"strings"
	"time"

	cmtproto "github.com/cometbft/cometbft/api/cometbft/types/v1"
	cmtversion "github.com/cometbft/cometbft/api/cometbft/version/v1"
	"github.com/cometbft/cometbft/crypto/ed25519"
	"github.com/cometbft/cometbft/libs/protoio"
	"github.com/cometbft/cometbft/types"
	"github.com/cometbft/cometbft/version"
)

func main() {
	var (
		chainID         = flag.String("chainid", "atomone-1", "")
		height          = flag.Int64("height", 1, "height of the block")
		privkeysStr     = flag.String("privkeys", "", "base64 encoded private key (sep by comma)")
		appHashSeed     = flag.String("apphash-seed", "", "will be hashed to create the apphash")
		headerTimeShift = flag.Int64("header-time-shift", 0, "number of minutes to add to the default gno time (2009-02-13) for the header timestamp")
	)
	flag.Parse()
	var privks []ed25519.PrivKey
	var vals []*types.Validator
	if *privkeysStr != "" {
		for s := range strings.SplitSeq(*privkeysStr, ",") {
			priv := ed25519.PrivKey(b64Dec(s))
			privks = append(privks, priv)
			vals = append(vals, types.NewValidator(priv.PubKey(), 1))
		}
	} else {
		priv := ed25519.GenPrivKey()
		privks = append(privks, priv)
		vals = append(vals, types.NewValidator(priv.PubKey(), 1))
	}

	var (
		valset                = types.ValidatorSet{Validators: vals}
		round           int64 = 0
		commitTimestamp       = toTime("2025-09-25T07:55:57.306746166Z")
		headerTimestamp       = time.Unix(1234567890, 0).Add(time.Minute * time.Duration(*headerTimeShift))
		apphash               = hash(*appHashSeed)
		header                = types.Header{
			Version: cmtversion.Consensus{
				Block: version.BlockProtocol,
				App:   0,
			},
			ChainID: *chainID,
			Height:  *height,
			Time:    headerTimestamp,
			LastBlockID: types.BlockID{
				Hash: hash("last_block_hash"),
				PartSetHeader: types.PartSetHeader{
					Total: 1,
					Hash:  hash("last_block_partset_hash"),
				},
			},
			LastCommitHash:     hash("last_commit_hash"),
			DataHash:           hash("data_hash"),
			ValidatorsHash:     valset.Hash(),
			NextValidatorsHash: valset.Hash(),
			ConsensusHash:      hash("consensus_hash"),
			AppHash:            apphash,
			LastResultsHash:    hash("last_results_hash"),
			EvidenceHash:       hash("evidence_hash"),
			ProposerAddress:    valset.Validators[0].Address,
		}
		vote = cmtproto.CanonicalVote{
			Type:   types.PrecommitType,
			Height: *height,
			Round:  round,
			BlockID: &cmtproto.CanonicalBlockID{
				Hash: header.Hash(),
				PartSetHeader: cmtproto.CanonicalPartSetHeader{
					Total: 1,
					Hash:  hash("block_partset_hash"),
				},
			},
			Timestamp: commitTimestamp,
			ChainID:   *chainID,
		}
	)
	bz, err := protoio.MarshalDelimited(&vote)
	if err != nil {
		panic(err)
	}
	fmt.Printf("HEADER HASH %x\n", header.Hash())

	for i, val := range vals {
		fmt.Printf("validator #%d:\n", i)
		fmt.Printf("\taddress:%s\n", base64.StdEncoding.EncodeToString(val.PubKey.Address()))
		fmt.Printf("\tpubkey:%s\n", base64.StdEncoding.EncodeToString(val.PubKey.Bytes()))
		fmt.Printf("\tprivkey:%s\n", base64.StdEncoding.EncodeToString(privks[i].Bytes()))

		signature, err := privks[i].Sign(bz)
		if err != nil {
			panic(err)
		}

		bz, _ = json.MarshalIndent(vote, "\t", "  ")
		fmt.Printf("\tvote: %s\n", string(bz))
		fmt.Printf("\tsignature: %s\n", base64.StdEncoding.EncodeToString(signature))
	}
	fmt.Println(headerTimestamp.UTC())
}

func b64Dec(s string) []byte {
	bz, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return bz
}

func toTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		panic(err)
	}
	return t
}

func hash(s string) []byte {
	bz := sha256.Sum256([]byte(s))
	return bz[:]
}
