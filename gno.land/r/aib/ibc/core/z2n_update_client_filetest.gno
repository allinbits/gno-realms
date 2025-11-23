package main

import (
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient fail because non-adjacent update has duplicate validator vote
func main() {
	// CreateClient and RegisterCounterparty
	var (
		chainID     = "atomone-1"
		height      = uint64(2)
		clientState = tmtesting.NewClientState(chainID, types.NewHeight(1, height))
		apphash     = tmtesting.GenHash("apphash-2")
		// priv=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==
		val1 = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
			"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 2)
		// priv=nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
		val2 = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
			"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 3)
		valset         = tendermint.NewValset(val1, val2)
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, valset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("prefix1"), []byte("prefix2")}, "07-tendermint-2")

	// Update clientID
	apphash = tmtesting.GenHash("apphash-5")
	var (
		newHeight     = height + 3 // non adjacent heigth 5
		newTimestamp  = consensusState.Timestamp.Add(time.Minute)
		blockhash     = tmtesting.B64Dec("NpiImIJoaSaIucwNs5cqpgMsL/8wxEPYC3P0jA5aQSI=")
		parsethash    = tmtesting.B64Dec("QqzwnLzvixIcUz+hPeUQjDV6NaLkFRKXACCxJIrBHzw=")
		consensushash = tmtesting.B64Dec("JIS7qLmeUx4aP2QiNi59PuuZqDJRGZaKNV8FwJ7t1As=")
		trustedValset = tendermint.NewValset(val1, val2)
		trustedHeight = clientState.LatestHeight
		// NOTE: signatures generated thanks to:
		// ./cmd/gen-block-signatures -privkeys=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==,nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
		signatures = []tendermint.CommitSig{
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[0].Address,
				Timestamp:        tmtesting.ToTime("2025-09-25T07:55:57.306746166Z"),
				Signature:        tmtesting.B64Dec("dXO4Y8p5cKwubGLT0vkSVu4UpJRfrocMVeD02r9FP6w+WzOT2WIars/BJH1xvIM0x9MutOF6utFbqwi9YFQ+CA=="),
			},
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[0].Address,
				Timestamp:        tmtesting.ToTime("2025-09-25T07:55:57.306746166Z"),
				Signature:        tmtesting.B64Dec("TwSjd4gWQExpna4o7WmfgjuhVr3gWD14dcxEez7kxt9Fd3eUChDOj/lGFNkllLJvX3lcSuHtsRK2KPsIfRaKBQ=="),
			},
		}

		msgHeader = tendermint.NewMsgHeader(
			chainID, newTimestamp, apphash, blockhash, parsethash, consensushash,
			newHeight, trustedHeight, valset, trustedValset, signatures,
		)
	)

	core.UpdateClient(cross, clientID, msgHeader)

	println("----------- assert render clients")
	println(core.Render("clients"))
	println("----------- assert render clients/07-tendermint-1/consensus_states")
	println(core.Render("clients/" + clientID + "/consensus_states"))
}

// Error:
// double vote from f4320162beb8af2c0a3b72a4ebeef8df10c77045 (0 and 1)
