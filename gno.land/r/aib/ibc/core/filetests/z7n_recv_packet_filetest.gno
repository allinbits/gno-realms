// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/r/aib/ibc/core"
)

// RecvPacket fails multiple payloads
func main(cur realm) {
	var (
		chainID        = "chain-id-2"
		trustedHeight  = types.NewHeight(2, 2)
		clientState    = tmtesting.NewClientState(chainID, trustedHeight)
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// A multi-payload packet is rejected before any app callback runs, so a
	// failing payload can never leave the state changes of a preceding
	// successful payload committed.
	recvPacket := types.MsgRecvPacket{
		Packet: types.Packet{
			Sequence:          1,
			SourceClient:      "07-tendermint-2",
			DestinationClient: clientID,
			TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
			Payloads: []types.Payload{
				{
					SourcePort:      "appID",
					DestinationPort: "destinationPort",
					Encoding:        "application/json",
					Value:           []byte("{}"),
					Version:         "v1",
				},
				{
					SourcePort:      "appID",
					DestinationPort: "destinationPort",
					Encoding:        "application/json",
					Value:           []byte("{}"),
					Version:         "v1",
				},
			},
		},
		ProofCommitment: []ics23.CommitmentProof{
			ics23.CommitmentProof_Exist{
				Exist: &ics23.ExistenceProof{},
			},
		},
		ProofHeight:     trustedHeight,
	}

	core.RecvPacket(cross(cur), recvPacket)
}

// Error:
// payloads must contain exactly one payload
