package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"strings"
	"time"

	cmtproto "github.com/cometbft/cometbft/api/cometbft/types/v1"
	"github.com/cometbft/cometbft/crypto/ed25519"
	"github.com/cometbft/cometbft/libs/protoio"
	"github.com/cometbft/cometbft/types"
)

func main() {
	var (
		privkeysStr = flag.String("privkeys", "", "base64 encoded private key (sep by comma)")
		height      = flag.Int64("height", 1, "height of the block")
	)
	flag.Parse()
	var privks []ed25519.PrivKey
	if *privkeysStr != "" {
		for s := range strings.SplitSeq(*privkeysStr, ",") {
			privks = append(privks, ed25519.PrivKey(b64Dec(s)))
		}
	} else {
		privks = append(privks, ed25519.GenPrivKey())
	}
	for i, privk := range privks {
		fmt.Printf("validator #%d:\n", i)
		fmt.Printf("\taddress:%s\n", base64.StdEncoding.EncodeToString(privk.PubKey().Address()))
		fmt.Printf("\tpubkey:%s\n", base64.StdEncoding.EncodeToString(privk.PubKey().Bytes()))
		fmt.Printf("\tprivkey:%s\n", base64.StdEncoding.EncodeToString(privk.Bytes()))

		var (
			chainID          = "atomone-1"
			round      int64 = 0
			timestamp        = toTime("2025-09-25T07:55:57.306746166Z")
			blockhash        = b64Dec("k9TcNAOVmzwiKh8cV6rgnBq4sWwDTaV6fPE6bSk8Qeg=")
			parsethash       = b64Dec("EFyo+pytQSBioZCew+q09sXCreheJhaouHEQ7CWYulA=")
			vote             = cmtproto.CanonicalVote{
				Type:   types.PrecommitType,
				Height: *height,
				Round:  round,
				BlockID: &cmtproto.CanonicalBlockID{
					Hash: blockhash,
					PartSetHeader: cmtproto.CanonicalPartSetHeader{
						Total: 1,
						Hash:  parsethash,
					},
				},
				Timestamp: timestamp,
				ChainID:   chainID,
			}
		)
		bz, err := protoio.MarshalDelimited(&vote)
		if err != nil {
			panic(err)
		}

		signature, err := privk.Sign(bz)
		if err != nil {
			panic(err)
		}

		bz, _ = json.MarshalIndent(vote, "\t", "  ")
		fmt.Printf("\tvote: %s\n", string(bz))
		fmt.Printf("\tsignature: %s\n", base64.StdEncoding.EncodeToString(signature))
	}
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
