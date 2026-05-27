// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// Timeout unauthorized relayer
func main(cur realm) {
	core.SetAdmin(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
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

	var (
		app       = appstesting.NewApp(cross(cur))
		appPortID = "app"
	)
	core.RegisterApp(cross(cur), appPortID, app)

	sendPacket := types.MsgSendPacket{
		SourceClient:     clientID,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      appPortID,
			DestinationPort: "destinationPort",
			Encoding:        "application/json",
			Value:           []byte("{}"),
			Version:         "v1",
		}},
	}
	sequence := core.SendPacket(cross(cur), sendPacket)

	timeoutPacket := types.MsgTimeout{
		Packet: types.Packet{
			Sequence:          sequence,
			SourceClient:      clientID,
			DestinationClient: counterpartyID,
			TimeoutTimestamp:  1,
			Payloads:          sendPacket.Payloads,
		},
		ProofUnreceived: []ics23.CommitmentProof{
			ics23.CommitmentProof_Nonexist{
				Nonexist: &ics23.NonExistenceProof{},
			},
		},
		ProofHeight: trustedHeight,
	}

	testing.SetOriginCaller("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx")
	core.Timeout(cross(cur), timeoutPacket)
}

// Error:
// unauthorized relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx
