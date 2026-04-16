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

// RecvPacket unauthorized relayer
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

	var (
		app       = appstesting.NewApp(cross)
		appPortID = "appID"
	)
	app.SetOnRecvPacketReturn(types.RecvPacketResult{
		Status:          types.PacketStatus_Success,
		Acknowledgement: []byte{0x01},
	})
	core.RegisterApp(cross, appPortID, app)

	recvPacket := types.MsgRecvPacket{
		Packet: types.Packet{
			Sequence:          1,
			SourceClient:      counterpartyID,
			DestinationClient: clientID,
			TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
			Payloads: []types.Payload{{
				SourcePort:      "appID",
				DestinationPort: "appID",
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

	testing.SetOriginCaller("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx")
	core.RecvPacket(cross, recvPacket)
}

// Error:
// expected relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm for client 07-tendermint-1, got g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsx
