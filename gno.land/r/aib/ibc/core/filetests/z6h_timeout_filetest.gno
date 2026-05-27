// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// Timeout no commitment found returns noop (res=1)
func main(cur realm) {
	var (
		chainID        = "chain-id-2"
		trustedHeight  = types.NewHeight(2, 2)
		clientState    = tmtesting.NewClientState(chainID, trustedHeight)
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
		counterpartyID = "07-tendermint-42"
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)
	// Register app
	var (
		app       = appstesting.NewApp(cross(cur))
		appPortID = "app"
	)
	core.RegisterApp(cross(cur), appPortID, app)

	// Timeout the packet
	timeoutPacket := types.MsgTimeout{
		Packet: types.Packet{
			Sequence:          42,
			SourceClient:      clientID,
			DestinationClient: counterpartyID,
			TimeoutTimestamp:  1,
			Payloads: []types.Payload{{
				SourcePort:      appPortID,
				DestinationPort: "destinationPort",
				Encoding:        "application/json",
				Value:           []byte("{}"),
				Version:         "v1",
			}},
		},
		ProofUnreceived: []ics23.CommitmentProof{
			ics23.CommitmentProof_Nonexist{
				Nonexist: &ics23.NonExistenceProof{},
			},
		},
		ProofHeight: trustedHeight,
	}

	res := core.Timeout(cross(cur), timeoutPacket)

	println("res:", res)
}

// Output:
// res: (1 gno.land/p/aib/ibc/types.ResponseResultType)
