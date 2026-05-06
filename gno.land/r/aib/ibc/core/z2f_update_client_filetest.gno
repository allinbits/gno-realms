package main

import (
	"errors"
	"time"

	"gno.land/p/aib/ibc/lightclient"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// validateError implements ClientMessage in order to returns an error when
// ValidateBasic() is invoked.
type validateError struct{}

func (validateError) ValidateBasic() error {
	return errors.New("validate error")
}

func (validateError) ClientType() string {
	return lightclient.Tendermint
}

// UpdateClient assert
// Assert calls to clientMessage.ValidateBasic
// NOTE: We don't want to test ValidateBasic() checks in filetest because it
// has too many cases, hence ValidateBasic is tested in unittests and we only
// ensure that the ValidateBasic() method are properly invoked.
func main() {
	// CreateClient and RegisterCounterparty
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Update clientID
	println("clientMessage.ValidateBasic():",
		// NOTE: panics in explicit cross realm can only be caught by revive.
		revive(func() {
			core.UpdateClient(cross, clientID, validateError{})
		}))
}

// Output:
// clientMessage.ValidateBasic(): validate error
