package main

import (
	"chain"
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// Transfer: native denom is rejected when the caller is not a direct user
// call. This is the maketx-run / wrapper-realm scenario the IsUserCall guard
// exists to block: -send can land elsewhere than this realm, so OriginSend
// cannot be trusted.
func main() {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Deliberately no testing.SetRealm(NewUserRealm(...)) — default package
	// main caller fails IsUserCall(), matching maketx run / wrapper realm.
	// OriginSend is set to prove the guard fires before any amount check.
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 100)))
	transfer.Transfer(cross, clientID, "atone1user", "ugnot", 100, uint64(time.Now().Add(time.Hour).Unix()), "")
}

// Error:
// native transfer must be a direct user call (maketx call)
