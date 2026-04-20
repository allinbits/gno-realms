package main

import (
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// RecoverClient failure: substitute client is not Active (Frozen here).
// Both subject and substitute are created with the same initial state, then
// frozen via the same misbehaviour message.
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	var (
		chainID     = "atomone-1"
		height      = uint64(2)
		clientState = tmtesting.NewClientState(chainID, types.NewHeight(1, height))
		apphash     = tmtesting.Hash("apphash-2")
		val1        = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
			"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)
		val2 = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
			"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 1)
		trustedValset  = tendermint.NewValset(val1, val2)
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	subjectID := core.CreateClient(cross, clientState, consensusState)
	substituteID := core.CreateClient(cross, clientState, consensusState)

	misbehaviour := buildMisbehaviour(chainID, clientState.LatestHeight, trustedValset, consensusState.Timestamp)
	core.UpdateClient(cross, subjectID, misbehaviour)
	core.UpdateClient(cross, substituteID, misbehaviour)

	core.RecoverClient(cross, subjectID, substituteID)
}

func buildMisbehaviour(chainID string, trustedHeight types.Height,
	trustedValset *tendermint.ValidatorSet, baseTime time.Time,
) *tendermint.Misbehaviour {
	var header1, header2 *tendermint.MsgHeader
	{
		var (
			apphash         = tmtesting.Hash("apphash-4")
			val1            = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=", "VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 10)
			val2            = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=", "NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 10)
			valset          = tendermint.NewValset(val1, val2)
			commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
			newHeight       = uint64(4)
			nextValset      = tendermint.NewValset(val1, val2)
			signatures      = []tendermint.CommitSig{
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[0].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x2e\xba\x21\xb0\x2f\xd2\x85\xb9\xef\x82\x68\xdc\xef\xd1\xd1\x12\x70\x88\x94\x10\x7e\x4d\x49\xac\x46\x3d\x86\xe2\xf2\xae\x38\xb4\xa5\xab\x0c\xc1\x8f\x8a\x59\xda\x36\x17\x01\xe4\x16\x49\xbf\x03\x86\xf0\x31\x3f\x30\x37\x9e\x47\x28\x72\x3b\x0c\x89\xb9\x94\x05"),
				},
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[1].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x67\xcc\xc6\xc4\x20\xa0\xcb\x36\xaf\x33\x5c\xf8\xe4\xad\x47\x49\x38\x9d\x9e\xa3\x7c\xe6\x88\x81\x62\x51\x7f\xcc\xa5\x92\x0d\x98\xe9\xbe\x71\x2d\x22\xcd\x41\x30\x28\x83\x03\xcb\xf5\xd7\x28\xde\x7b\x92\x85\x9e\xa6\xe5\xde\x50\x89\x2d\x2b\xc5\x9d\x9a\x33\x00"),
				},
			}
		)
		header1 = tmtesting.NewMsgHeader(chainID, baseTime, apphash, newHeight,
			trustedHeight, valset, nextValset, trustedValset, signatures)
	}
	{
		var (
			apphash         = tmtesting.Hash("apphash-3")
			val1            = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=", "VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 10)
			val2            = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=", "NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 10)
			valset          = tendermint.NewValset(val1, val2)
			commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
			newHeight       = uint64(3)
			nextValset      = tendermint.NewValset(val1, val2)
			signatures      = []tendermint.CommitSig{
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[0].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x51\xa4\x8f\x78\x42\x4e\x6e\x0d\xc3\x2b\xe6\xcb\x09\x5c\xe5\x7d\x35\x84\xcf\xb1\x0f\x53\x72\x0c\x41\xde\xd3\x6d\xbc\x81\x28\x64\x41\xf7\xe9\x1e\xa9\x93\xd0\xa4\x84\x16\xca\xa8\xa3\x8e\x56\x45\xec\xae\x1d\x24\xb4\xa8\xf4\x29\x85\x04\x06\xe4\x18\x6b\x7d\x08"),
				},
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[1].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\xd9\xd6\x82\x83\x78\x75\xfa\x2e\xd7\x1b\xa5\x3d\xfe\xb3\x80\xb6\xc7\x59\x20\x45\x10\xdf\x0c\x19\xd1\xcc\xfc\x37\xd5\x59\x79\x95\x93\x60\x08\xfb\x5f\xa0\x87\x95\x51\x1e\x29\xed\x94\xd1\x31\x5e\xda\x90\x86\x11\xbe\xb2\x88\x68\xe1\xba\xa7\x31\xc7\xa2\xda\x07"),
				},
			}
		)
		header2 = tmtesting.NewMsgHeader(chainID, baseTime, apphash, newHeight,
			trustedHeight, valset, nextValset, trustedValset, signatures)
	}
	return &tendermint.Misbehaviour{Header1: header1, Header2: header2}
}

// Error:
// substitute client 07-tendermint-2 must be Active, got Frozen
