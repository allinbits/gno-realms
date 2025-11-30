package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient consensusState.NextValidatorHash and trustedValset mismatch
func main() {
	// CreateClient and RegisterCounterparty
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		valset         = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, valset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Update clientID
	var (
		newHeight     = clientState.LatestHeight.RevisionHeight + 1
		newTimestamp  = consensusState.Timestamp.Add(time.Minute)
		trustedValset = tmtesting.GenValset()
		trustedHeight = clientState.LatestHeight
		msgHeader     = tmtesting.GenMsgHeader(
			chainID, newTimestamp, apphash, newHeight, trustedHeight, valset,
			trustedValset,
		)
	)
	// Alter trustedvalset
	trustedValset.Validators[0].VotingPower = 42
	msgHeader.Header.NextValidatorsHash = trustedValset.Hash()

	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// trusted validators does not hash to latest trusted validators. Expected: "4e201092fa289bdef1e42bbaafd4efa1a95c98e5c7e8193e24b5511c6b44023c", got: "6429cc1fe212aa6abef2565ac6e9abcfd8171f2a7cdce6cf64a0c321d5ea1145"
