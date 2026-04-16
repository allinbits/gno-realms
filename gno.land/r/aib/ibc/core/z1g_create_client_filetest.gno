package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// CreateClient and RegisterCounterparty have different signer
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)

	clientID := core.CreateClient(cross, clientState, consensusState)

	// Change OriginCaller for the call to RegisterCounterparty
	ctx := testing.GetContext()
	ctx.OriginCaller = "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx"
	testing.SetContext(ctx)

	// RegisterCounterparty on clientID
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")
}

// Error:
// expected same signer as CreateClient submitter g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm, got g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx
