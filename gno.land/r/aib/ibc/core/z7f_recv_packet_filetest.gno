package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/r/aib/ibc/core"
)

// RecvPacket fails timestamp > timeoutTimestamp
func main() {
	var (
		chainID        = "chain-id-2"
		trustedHeight  = types.NewHeight(2, 2)
		clientState    = tmtesting.NewClientState(chainID, trustedHeight)
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
		counterpartyID = "07-tendermint-42"
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)

	// Receive the packet
	recvPacket := types.MsgRecvPacket{
		Packet: types.Packet{
			Sequence:          1,
			SourceClient:      counterpartyID,
			DestinationClient: clientID,
			TimeoutTimestamp:  1,
			Payloads: []types.Payload{{
				SourcePort:      "appID",
				DestinationPort: "destinationPort",
				Encoding:        "application/json",
				Value:           []byte("{}"),
				Version:         "v1",
			}},
		},
		ProofCommitment: []ics23.CommitmentProof{
			ics23.CommitmentProof_Exist{
				Exist: &ics23.ExistenceProof{},
			},
		},
		ProofHeight: trustedHeight,
	}

	core.RecvPacket(cross, recvPacket)
}

// Error:
// current timestamp: 1234567890, timeout timestamp: 1
