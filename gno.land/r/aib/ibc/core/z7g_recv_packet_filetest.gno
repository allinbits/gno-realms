package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/r/aib/ibc/core"
)

// RecvPacket fails wrong number of proofs compared to specs
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
			TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
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
// failed packet commitment verification for client (07-tendermint-1): length of specs: 2 not equal to length of proof: 1
