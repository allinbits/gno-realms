package main

import (
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient unauthorized relayer
func main() {
	var (
		chainID     = "atomone-1"
		height      = uint64(2)
		clientState = tmtesting.NewClientState(chainID, types.NewHeight(1, height))
		apphash     = tmtesting.Hash("apphash-2")
		// priv=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==
		val1 = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
			"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)
		// priv=nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
		val2 = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
			"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 1)
		trustedValset  = tendermint.NewValset(val1, val2)
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	var (
		commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
		newHeight       = height + 1
		newTimestamp    = consensusState.Timestamp.Add(time.Minute)
		newApphash      = tmtesting.Hash("apphash-3")
		valset          = tendermint.NewValset(val1, val2)
		nextValset      = tendermint.NewValset(val1, val2)
		trustedHeight   = clientState.LatestHeight

		signatures = []tendermint.CommitSig{
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[0].Address,
				Timestamp:        commitTimestamp,
				Signature:        []byte("\x5c\xd2\x8b\xe3\x4b\x60\x3e\xaa\x75\x3c\xce\x24\xfe\x15\x75\x55\x84\xd4\xa3\xce\xbe\x0f\x94\xe9\xf7\x27\xb3\x7a\xdd\x02\x2d\xa0\x0b\xa7\x83\x7f\x50\xc3\xde\x3d\x95\x59\xb3\xad\xed\xd0\xdd\x23\x1d\x39\x9a\x8e\x1f\xc3\xcf\xdb\x1d\xa9\x93\xf5\x9a\xc0\x2b\x05"),
			},
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[1].Address,
				Timestamp:        commitTimestamp,
				Signature:        []byte("\x34\x41\x2e\x78\x7f\xbf\x70\xef\x14\x48\xe3\x14\xd5\x83\xdc\x42\xff\x40\xf6\x5b\x71\x62\x09\xf9\x6f\x54\x63\x3e\xdb\xc5\x98\xc0\x9e\xa7\xde\x33\xac\xa7\x5f\xbb\xd6\x63\x49\xe1\xe9\x98\x86\x03\x46\x6a\x7e\xb6\x5d\xe5\x71\xe5\x1e\x5d\x4d\xd8\x8d\xbe\x2f\x01"),
			},
		}

		msgHeader = tmtesting.NewMsgHeader(
			chainID, newTimestamp, newApphash, newHeight, trustedHeight, valset,
			nextValset, trustedValset, signatures,
		)
	)

	testing.SetOriginCaller("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx")
	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// expected relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm for client 07-tendermint-1, got g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx
